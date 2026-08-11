import Foundation
import XCTest

@testable import CompetitionCore

final class CompetitionReplayTests: XCTestCase {
    private let competitionID = CompetitionID(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    private let engine = CompetitionEngine()

    func testGenesisReplaysPendingProjectionWithoutPersistingAggregate() throws {
        let genesis = try makeGenesis()
        let journal = try CompetitionJournal(genesis: genesis)

        let projection = try CompetitionReplayer.replay(journal)

        XCTAssertEqual(
            projection.competition,
            Competition.pending(
                id: competitionID,
                direction: .incoming,
                createdAt: date(2026, 8, 9, 10),
                expiresAt: date(2026, 8, 10, 10)
            )
        )
        XCTAssertEqual(
            projection.scoreLedger,
            ScoreLedger(
                scoringPolicy: .appleCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        )
        XCTAssertEqual(journal.cursor.eventCount, 0)
        XCTAssertEqual(journal.cursor.commitRevision, 0)
    }

    func testUnknownOnlyPausePolicyPersistsThroughGenesisAndReplay() throws {
        let policy = ActivityScoringPolicy.healthKitCompatibility
        let genesis = try CompetitionGenesis(
            competitionID: competitionID,
            direction: .incoming,
            createdAt: date(2026, 8, 9, 10),
            expiresAt: date(2026, 8, 10, 10),
            scoringPolicy: policy,
            downwardRevisionPolicy: .maximumObserved
        )
        let roundTripped = try pinnedDecoder().decode(
            CompetitionGenesis.self,
            from: pinnedEncoder().encode(genesis)
        )
        let projection = try CompetitionReplayer.replay(
            CompetitionJournal(genesis: roundTripped)
        )

        XCTAssertEqual(roundTripped.scoringPolicy, policy)
        XCTAssertEqual(projection.scoreLedger.scoringPolicy, policy)
        XCTAssertEqual(
            projection.scoreLedger.scoringPolicy.identity,
            policy.identity
        )
        XCTAssertEqual(
            ActivityScoringPolicy.appleCompatibility.pausedSummaryPolicy,
            .unavailable
        )
    }

    func testLoadedCompetitionJournalDerivesProjectionFromValidatedRoundTrip() throws {
        let original = try acceptedJournal()
        let roundTripped = try pinnedDecoder().decode(
            CompetitionJournal.self,
            from: pinnedEncoder().encode(original)
        )
        let loaded = try LoadedCompetitionJournal(
            journal: roundTripped,
            source: .recoveredPrevious
        )

        XCTAssertEqual(loaded.journal, original)
        XCTAssertEqual(
            loaded.projection,
            try CompetitionReplayer.replay(original)
        )
        XCTAssertEqual(loaded.source, .recoveredPrevious)
    }

    func testLifecycleAndActivityEventsReplayInStoredSequenceOrder() throws {
        var journal = try CompetitionJournal(genesis: makeGenesis(expiresAt: nil))
        var live = journal.genesis.makeCompetition()
        let acceptance = try engine.accept(
            live,
            at: date(2026, 8, 9, 11),
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        try engine.apply(acceptance, to: &live)
        let refresh = try dayOneRefresh(
            in: CompetitionReplayer.replay(acceptedJournal()),
            attemptID: "watch-day-1-a",
            ordinal: 1,
            readAt: date(2026, 8, 10, 12),
            snapshot: try snapshot(points: 450)
        )

        let result = try journal.append(
            [.lifecycle(acceptance), .activityRefreshAttemptRecorded(refresh)],
            expectedCursor: journal.cursor
        )
        let projection = try CompetitionReplayer.replay(journal)

        XCTAssertEqual(result.appendedCount, 2)
        XCTAssertEqual(journal.envelopes.map(\.sequence), [1, 2])
        XCTAssertEqual(projection.competition, live)
        XCTAssertEqual(
            projection.scoreLedger.entry(forDayOrdinal: 1)?.acceptedScore?.points,
            450
        )
    }

    func testExactDuplicateIsByteAndCursorStableButDivergentPayloadConflicts() throws {
        var journal = try CompetitionJournal(genesis: makeGenesis(expiresAt: nil))
        let event = try dayOneRefresh(
            in: CompetitionReplayer.replay(acceptedJournal()),
            attemptID: "day-1-reading",
            ordinal: 1,
            readAt: date(2026, 8, 10, 12),
            snapshot: try snapshot(points: 300)
        )
        let acceptance = try acceptanceEvent()
        _ = try journal.append(
            [.lifecycle(acceptance), .activityRefreshAttemptRecorded(event)],
            expectedCursor: journal.cursor
        )
        let before = try pinnedEncoder().encode(journal)
        let staleCursor = try CompetitionJournal(genesis: makeGenesis(expiresAt: nil)).cursor

        let retry = try journal.append(
            [.activityRefreshAttemptRecorded(event)],
            expectedCursor: staleCursor
        )

        XCTAssertEqual(retry.appendedCount, 0)
        XCTAssertEqual(try pinnedEncoder().encode(journal), before)
        XCTAssertThrowsError(
            try journal.append(
                [
                    .activityRefreshAttemptRecorded(
                        try dayOneRefresh(
                            in: CompetitionReplayer.replay(acceptedJournal()),
                            attemptID: "day-1-reading",
                            ordinal: 1,
                            readAt: date(2026, 8, 10, 12, 1),
                            snapshot: try snapshot(points: 300)
                        )
                    ),
                ],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .semanticEventConflict(eventID: event.semanticEventID)
            )
        }
        XCTAssertEqual(try pinnedEncoder().encode(journal), before)
    }

    func testDecodeRejectsUnsupportedJournalVersionPrecisely() throws {
        let journal = try CompetitionJournal(genesis: makeGenesis())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: pinnedEncoder().encode(journal))
                as? [String: Any]
        )
        object["journalVersion"] = 999
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try pinnedDecoder().decode(CompetitionJournal.self, from: data)
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .upgradeRequiredJournalVersion(found: 999)
            )
        }
    }

    func testMixedDuplicateAndNewBatchAppendsOnlyNewEventAtCurrentCursor() throws {
        var journal = try acceptedJournal()
        let first = try dayOneRefresh(
            in: CompetitionReplayer.replay(journal),
            attemptID: "mixed-first",
            ordinal: 1,
            readAt: date(2026, 8, 10, 9),
            snapshot: try snapshot(points: 200)
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(first)],
            expectedCursor: journal.cursor
        )
        let beforeMixedCursor = journal.cursor
        let second = try dayOneRefresh(
            in: CompetitionReplayer.replay(journal),
            attemptID: "mixed-second",
            ordinal: 2,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 400)
        )

        let result = try journal.append(
            [
                .activityRefreshAttemptRecorded(first),
                .activityRefreshAttemptRecorded(second),
            ],
            expectedCursor: beforeMixedCursor
        )

        XCTAssertEqual(result.appendedCount, 1)
        XCTAssertEqual(result.cursor.eventCount, beforeMixedCursor.eventCount + 1)
        XCTAssertEqual(result.cursor.commitRevision, beforeMixedCursor.commitRevision + 1)
        XCTAssertEqual(journal.envelopes.last?.semanticEventID, second.semanticEventID)
        XCTAssertEqual(
            try CompetitionReplayer.replay(journal)
                .scoreLedger.entry(forDayOrdinal: 1)?.acceptedScore?.points,
            400
        )
    }

    func testSameIDWithinBatchCollapsesWhenEqualAndConflictsWhenUnequal() throws {
        var journal = try acceptedJournal()
        let equal = try dayOneRefresh(
            in: CompetitionReplayer.replay(journal),
            attemptID: "same-batch-id",
            ordinal: 1,
            readAt: date(2026, 8, 10, 9),
            snapshot: try snapshot(points: 200)
        )
        let result = try journal.append(
            [
                .activityRefreshAttemptRecorded(equal),
                .activityRefreshAttemptRecorded(equal),
            ],
            expectedCursor: journal.cursor
        )

        XCTAssertEqual(result.appendedCount, 1)
        let beforeConflict = journal
        let afterEqual = try CompetitionReplayer.replay(journal)
        XCTAssertThrowsError(
            try journal.append(
                [
                    .activityRefreshAttemptRecorded(
                        try dayOneRefresh(
                            in: afterEqual,
                            attemptID: "divergent-batch-id-a",
                            ordinal: 2,
                            readAt: date(2026, 8, 10, 10),
                            snapshot: try snapshot(points: 200)
                        )
                    ),
                    .activityRefreshAttemptRecorded(
                        try dayOneRefresh(
                            in: afterEqual,
                            attemptID: "divergent-batch-id-b",
                            ordinal: 2,
                            readAt: date(2026, 8, 10, 11),
                            snapshot: try snapshot(points: 300)
                        )
                    ),
                ],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .semanticEventConflict(
                    eventID: ActivityRefreshAttemptRecorded.semanticID(
                        competitionID: competitionID,
                        attemptOrdinal: 2
                    )
                )
            )
        }
        XCTAssertEqual(journal, beforeConflict)
    }

    func testStaleCursorWithAnyNewEventRejectsWithoutMutation() throws {
        var journal = try acceptedJournal()
        let stale = journal.cursor
        let first = try dayOneRefresh(
            in: CompetitionReplayer.replay(journal),
            attemptID: "already-committed",
            ordinal: 1,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 100)
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(first)],
            expectedCursor: stale
        )
        let before = journal
        let second = try dayOneRefresh(
            in: CompetitionReplayer.replay(journal),
            attemptID: "new-on-stale-cursor",
            ordinal: 2,
            readAt: date(2026, 8, 10, 9),
            snapshot: try snapshot(points: 200)
        )

        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(second)],
                expectedCursor: stale
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .cursorConflict(expected: stale, actual: before.cursor)
            )
        }
        XCTAssertEqual(journal, before)
    }

    func testInvalidLaterBatchEventLeavesJournalUnchanged() throws {
        var journal = try acceptedJournal()
        let before = journal
        let valid = try dayOneRefresh(
            in: CompetitionReplayer.replay(journal),
            attemptID: "valid-first",
            ordinal: 1,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 100)
        )
        let terminal = CompetitionEvent(
            competitionID: competitionID,
            occurredAt: date(2026, 8, 10, 9),
            kind: .competitionArchived
        )

        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(valid), .lifecycle(terminal)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .invalidDomainTransition(sequence: before.cursor.eventCount + 2)
            )
        }
        XCTAssertEqual(journal, before)
    }

    func testReplayKeepsNonmonotonicWallTimesInStoredSequenceOrder() throws {
        var journal = try acceptedJournal()
        let initial = try CompetitionReplayer.replay(journal)
        let laterTimestamp = try dayOneRefresh(
            in: initial,
            attemptID: "wall-clock-first",
            ordinal: 1,
            readAt: date(2026, 8, 10, 12),
            snapshot: try snapshot(points: 450)
        )
        let earlierTimestamp = try dayOneRefresh(
            in: initial,
            attemptID: "wall-clock-second",
            ordinal: 2,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 200)
        )
        _ = try journal.append(
            [
                .activityRefreshAttemptRecorded(laterTimestamp),
                .activityRefreshAttemptRecorded(earlierTimestamp),
            ],
            expectedCursor: journal.cursor
        )

        let projection = try CompetitionReplayer.replay(journal)

        XCTAssertEqual(
            projection.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot,
            try snapshot(points: 200)
        )
        XCTAssertEqual(
            projection.scoreLedger.entry(forDayOrdinal: 1)?.acceptedScore?.points,
            450
        )
    }

    func testJournalRelationshipRequiresExactEnvelopePrefix() throws {
        let base = try acceptedJournal()
        let empty = try CompetitionJournal(genesis: base.genesis)
        var descendant = base
        let projection = try CompetitionReplayer.replay(base)
        let child = try dayOneRefresh(
            in: projection,
            attemptID: "prefix-child",
            ordinal: 1,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 100)
        )
        _ = try descendant.append(
            [.activityRefreshAttemptRecorded(child)],
            expectedCursor: descendant.cursor
        )
        var divergent = base
        let differentChild = try dayOneRefresh(
            in: projection,
            attemptID: "different-child",
            ordinal: 1,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 100)
        )
        _ = try divergent.append(
            [.activityRefreshAttemptRecorded(differentChild)],
            expectedCursor: divergent.cursor
        )

        XCTAssertEqual(empty.relationship(to: base), .prefix)
        XCTAssertEqual(base.relationship(to: empty), .descendant)
        XCTAssertEqual(base.relationship(to: base), .equal)
        XCTAssertEqual(base.relationship(to: descendant), .prefix)
        XCTAssertEqual(descendant.relationship(to: base), .descendant)
        XCTAssertEqual(descendant.relationship(to: divergent), .divergent)
    }

    func testJournalRelationshipRejectsPrefixThatEndsInsideAtomicCommit() throws {
        let genesis = try makeGenesis(expiresAt: nil)
        let acceptance = try acceptanceEvent()
        let refresh = try dayOneRefresh(
            in: CompetitionReplayer.replay(acceptedJournal()),
            attemptID: "same-commit-second-event",
            ordinal: 1,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 100)
        )

        var singleEventCommit = try CompetitionJournal(genesis: genesis)
        _ = try singleEventCommit.append(
            [.lifecycle(acceptance)],
            expectedCursor: singleEventCommit.cursor
        )
        var twoEventCommit = try CompetitionJournal(genesis: genesis)
        _ = try twoEventCommit.append(
            [
                .lifecycle(acceptance),
                .activityRefreshAttemptRecorded(refresh),
            ],
            expectedCursor: twoEventCommit.cursor
        )

        XCTAssertEqual(
            singleEventCommit.envelopes,
            Array(twoEventCommit.envelopes.prefix(1))
        )
        XCTAssertEqual(
            singleEventCommit.relationship(to: twoEventCommit),
            .divergent
        )
        XCTAssertEqual(
            twoEventCommit.relationship(to: singleEventCommit),
            .divergent
        )
    }

    func testGenesisAndObservationDecodeRevalidateSourceFields() throws {
        XCTAssertThrowsError(
            try CompetitionGenesis(
                competitionID: competitionID,
                direction: .incoming,
                createdAt: Date(timeIntervalSinceReferenceDate: .nan),
                expiresAt: nil,
                scoringPolicy: .appleCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionGenesis.ValidationError,
                .invalidDate
            )
        }
        XCTAssertThrowsError(
            try CompetitionGenesis(
                competitionID: competitionID,
                direction: .incoming,
                createdAt: date(2026, 8, 10, 10),
                expiresAt: date(2026, 8, 10, 10),
                scoringPolicy: .appleCompatibility,
                downwardRevisionPolicy: .maximumObserved
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionGenesis.ValidationError,
                .expiryMustFollowCreation
            )
        }

        let recorded = try observation(
            id: "source-validation",
            at: date(2026, 8, 10, 8),
            points: 100
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: pinnedEncoder().encode(recorded))
                as? [String: Any]
        )
        object["dayOrdinal"] = 8
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                ActivitySnapshotRecorded.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivitySnapshotRecorded.ValidationError,
                .invalidDayOrdinal(8)
            )
        }
    }

    func testAcceptedOpponentPlanCommitmentIsByteIdenticalAcrossReplay() throws {
        let acceptance = try acceptanceEvent()
        let journal = try acceptedJournal()
        let replayed = try CompetitionReplayer.replay(journal)
        let replayedPlan = try XCTUnwrap(replayed.competition.opponentPlan)
        guard case let .invitationAccepted(configuration) = acceptance.kind else {
            return XCTFail("Fixture must produce an acceptance event")
        }

        XCTAssertEqual(
            replayedPlan.canonicalBytes,
            configuration.opponentPlan.canonicalBytes
        )
        XCTAssertEqual(replayedPlan.commitmentHex, configuration.opponentPlan.commitmentHex)
    }

    func testReplayMatchesLiveAggregateAtEveryScheduledLifecycleBoundary() throws {
        var journal = try acceptedJournal()
        var live = try CompetitionReplayer.replay(journal).competition
        XCTAssertEqual(live.lifecycle, .scheduled)

        for ordinal in 1...6 {
            let events = try engine.observeClock(
                live,
                at: date(2026, 8, 9 + ordinal, 0)
            )
            try engine.apply(events, to: &live)
            _ = try journal.append(
                events.map(CompetitionDomainEvent.lifecycle),
                expectedCursor: journal.cursor
            )

            XCTAssertEqual(
                try CompetitionReplayer.replay(journal).competition,
                live
            )
            XCTAssertEqual(
                live.lifecycle,
                .active(day: try CompetitionActiveDay(ordinal))
            )
        }

        let finalDayEvents = try engine.observeClock(
            live,
            at: date(2026, 8, 16, 0)
        )
        try engine.apply(finalDayEvents, to: &live)
        _ = try journal.append(
            finalDayEvents.map(CompetitionDomainEvent.lifecycle),
            expectedCursor: journal.cursor
        )
        XCTAssertEqual(live.lifecycle, .endsToday)
        XCTAssertEqual(try CompetitionReplayer.replay(journal).competition, live)

        let tallyEvents = try engine.observeClock(
            live,
            at: date(2026, 8, 17, 0)
        )
        try engine.apply(tallyEvents, to: &live)
        _ = try journal.append(
            tallyEvents.map(CompetitionDomainEvent.lifecycle),
            expectedCursor: journal.cursor
        )
        guard case .tallying = live.lifecycle else {
            return XCTFail("Fixture must reach tallying")
        }
        XCTAssertEqual(try CompetitionReplayer.replay(journal).competition, live)
    }

    func testReplayMatchesDeclinedAndExpiredTerminalInvitations() throws {
        var declinedJournal = try CompetitionJournal(genesis: makeGenesis())
        var declinedLive = declinedJournal.genesis.makeCompetition()
        let decline = try engine.decline(
            declinedLive,
            at: date(2026, 8, 9, 12)
        )
        try engine.apply(decline, to: &declinedLive)
        _ = try declinedJournal.append(
            [.lifecycle(decline)],
            expectedCursor: declinedJournal.cursor
        )
        XCTAssertEqual(
            try CompetitionReplayer.replay(declinedJournal).competition,
            declinedLive
        )

        var expiredJournal = try CompetitionJournal(genesis: makeGenesis())
        var expiredLive = expiredJournal.genesis.makeCompetition()
        let expiry = try XCTUnwrap(
            engine.observeClock(
                expiredLive,
                at: date(2026, 8, 10, 10)
            ).first
        )
        try engine.apply(expiry, to: &expiredLive)
        _ = try expiredJournal.append(
            [.lifecycle(expiry)],
            expectedCursor: expiredJournal.cursor
        )
        XCTAssertEqual(
            try CompetitionReplayer.replay(expiredJournal).competition,
            expiredLive
        )
    }

    func testScoreLedgerReplayPreservesHigherAcceptedLowerLatestAndWatchIncrease() throws {
        var journal = try acceptedJournal()
        let initial = try CompetitionReplayer.replay(journal)
        let snapshots = [
            try snapshot(points: 450),
            try snapshot(points: 200),
            try snapshot(points: 575),
        ]
        let refreshes = try zip(1...3, snapshots).map { ordinal, snapshot in
            try dayOneRefresh(
                in: initial,
                attemptID: "ledger-refresh-\(ordinal)",
                ordinal: UInt64(ordinal),
                readAt: date(2026, 8, 10, 7 + ordinal),
                snapshot: snapshot
            )
        }
        _ = try journal.append(
            refreshes.map(CompetitionDomainEvent.activityRefreshAttemptRecorded),
            expectedCursor: journal.cursor
        )
        let projection = try CompetitionReplayer.replay(journal)
        let entry = try XCTUnwrap(
            projection.scoreLedger.entry(forDayOrdinal: 1)
        )

        XCTAssertEqual(entry.latestEvidence.snapshot, snapshots[2])
        XCTAssertEqual(entry.acceptedScore?.points, 575)
        XCTAssertEqual(entry.acceptedScore?.snapshot, snapshots[2])
    }

    func testIncompleteFinalReadReplaysButForgedCompleteOwnerWindowIsAtomicFailure() throws {
        var journal = try tallyingJournal()
        let incomplete = try FinalReadEvidence(
            attemptID: "incomplete",
            readAt: date(2026, 8, 17, 0, 1),
            monotonicInstant: MonotonicInstant(
                epochID: "replay-test",
                nanoseconds: 1_000
            ),
            evaluableOrdinals: [],
            acceptedScoreOrdinals: [],
            missingOrdinals: [7],
            unavailableOrdinals: Set(1...6),
            completeWindowContent: nil,
            opponentPlanIsFinal: true
        )
        let incompleteProjection = try CompetitionReplayer.replay(journal)
        let incompleteEvent = try engine.recordFinalRead(
            incompleteProjection.competition,
            evidence: incomplete
        )
        let incompleteRefresh = try refreshBound(
            to: incomplete,
            in: incompleteProjection
        )
        _ = try journal.append(
            [
                .activityRefreshAttemptRecorded(incompleteRefresh),
                .lifecycle(incompleteEvent),
            ],
            expectedCursor: journal.cursor
        )
        guard case let .tallying(tally) = try CompetitionReplayer.replay(journal)
            .competition.lifecycle
        else {
            return XCTFail("Incomplete read must remain tallying")
        }
        XCTAssertEqual(tally.reconciliation.latestAttempt, incomplete)

        journal = try journalWithSevenOwnerDays(from: journal) { _ in 300 }
        let projection = try CompetitionReplayer.replay(journal)
        let validContent = try completeContent(for: projection)
        var forgedDays = validContent.days
        forgedDays[0] = WindowDayContent(
            ordinal: 1,
            userPoints: 301,
            opponentPoints: forgedDays[0].opponentPoints,
            activityContentFingerprint: forgedDays[0].activityContentFingerprint
        )
        let forged = try FinalReadEvidence(
            attemptID: "forged-owner",
            readAt: date(2026, 8, 17, 0, 2),
            monotonicInstant: MonotonicInstant(
                epochID: "replay-test",
                nanoseconds: 2_000
            ),
            evaluableOrdinals: Set(1...7),
            acceptedScoreOrdinals: Set(1...7),
            missingOrdinals: [],
            unavailableOrdinals: [],
            completeWindowContent: try CompleteWindowContent(
                days: forgedDays,
                opponentPlanVersion: validContent.opponentPlanVersion
            ),
            opponentPlanIsFinal: true
        )
        let forgedEvent = try engine.recordFinalRead(
            projection.competition,
            evidence: forged
        )
        let before = journal
        let forgedRefresh = try refreshBound(to: forged, in: projection)

        XCTAssertThrowsError(
            try journal.append(
                [
                    .activityRefreshAttemptRecorded(forgedRefresh),
                    .lifecycle(forgedEvent),
                ],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .ownerWindowMismatch(
                    sequence: before.cursor.eventCount + 2
                )
            )
        }
        XCTAssertEqual(journal, before)
    }

    func testCompletedWinLossTieReplayFreezesExactlySevenDaysAndArchiveReplays() throws {
        let win = try completedJournal { _, _ in 600 }
        let loss = try completedJournal { _, _ in 0 }
        let tie = try completedJournal { _, opponentPoints in opponentPoints }

        for (journal, expectedOutcome) in [
            (win, CompetitionOutcome.win),
            (loss, CompetitionOutcome.loss),
            (tie, CompetitionOutcome.tie),
        ] {
            let projection = try CompetitionReplayer.replay(journal)
            guard case let .completed(completed) = projection.competition.lifecycle else {
                return XCTFail("Fixture must replay completed")
            }
            XCTAssertEqual(completed.outcome, expectedOutcome)
            XCTAssertTrue(projection.scoreLedger.isFrozen)
            XCTAssertEqual(projection.scoreLedger.entries.map(\.ordinal), Array(1...7))
            XCTAssertTrue(projection.scoreLedger.entries.allSatisfy(\.isFrozen))
        }

        var archived = win
        let completed = try CompetitionReplayer.replay(archived).competition
        let archive = try engine.archive(
            completed,
            at: date(2026, 8, 17, 1)
        )
        _ = try archived.append(
            [.lifecycle(archive)],
            expectedCursor: archived.cursor
        )
        guard case .archived = try CompetitionReplayer.replay(archived)
            .competition.lifecycle
        else {
            return XCTFail("Archive must replay from completed")
        }
    }

    func testFinalReadOrdinalSetsHaveCanonicalSortedPayloadBytes() throws {
        var source = try tallyingJournal()
        source = try journalWithSevenOwnerDays(from: source) { _ in 300 }
        let projection = try CompetitionReplayer.replay(source)
        var ascending = Set<Int>()
        var descending = Set<Int>()
        for ordinal in 1...7 { ascending.insert(ordinal) }
        for ordinal in (1...7).reversed() { descending.insert(ordinal) }
        let firstEvidence = try completeEvidence(
            attemptID: "canonical-set-order",
            ordinals: ascending,
            projection: projection
        )
        let secondEvidence = try completeEvidence(
            attemptID: "canonical-set-order",
            ordinals: descending,
            projection: projection
        )
        let firstEvent = try engine.recordFinalRead(
            projection.competition,
            evidence: firstEvidence
        )
        let secondEvent = try engine.recordFinalRead(
            projection.competition,
            evidence: secondEvidence
        )
        let firstRefresh = try refreshBound(to: firstEvidence, in: projection)
        let secondRefresh = try refreshBound(to: secondEvidence, in: projection)
        var firstJournal = source
        var secondJournal = source
        _ = try firstJournal.append(
            [
                .activityRefreshAttemptRecorded(firstRefresh),
                .lifecycle(firstEvent),
            ],
            expectedCursor: firstJournal.cursor
        )
        _ = try secondJournal.append(
            [
                .activityRefreshAttemptRecorded(secondRefresh),
                .lifecycle(secondEvent),
            ],
            expectedCursor: secondJournal.cursor
        )

        let encodedEvidence = try pinnedEncoder().encode(firstEvidence)
        let evidenceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedEvidence) as? [String: Any]
        )
        XCTAssertEqual(
            evidenceObject["evaluableOrdinals"] as? [Int],
            Array(1...7)
        )
        XCTAssertEqual(
            evidenceObject["acceptedScoreOrdinals"] as? [Int],
            Array(1...7)
        )
        XCTAssertEqual(firstJournal.envelopes.last?.payload, secondJournal.envelopes.last?.payload)
        XCTAssertEqual(
            firstJournal.envelopes.last?.envelopeSHA256,
            secondJournal.envelopes.last?.envelopeSHA256
        )
        XCTAssertEqual(
            try pinnedEncoder().encode(firstJournal),
            try pinnedEncoder().encode(secondJournal)
        )
    }

    func testTamperedPayloadChainTailDocumentAndGenesisAreRejected() throws {
        let journal = try acceptedJournal()
        let cases: [(
            String,
            (inout [String: Any]) throws -> Void,
            CompetitionJournalError
        )] = [
            (
                "payload",
                { root in
                    var envelopes = try XCTUnwrap(root["envelopes"] as? [[String: Any]])
                    envelopes[0]["payload"] = Data([0x00]).base64EncodedString()
                    root["envelopes"] = envelopes
                },
                .payloadDigestMismatch(sequence: 1)
            ),
            (
                "chain",
                { root in
                    var envelopes = try XCTUnwrap(root["envelopes"] as? [[String: Any]])
                    envelopes[0]["previousEnvelopeSHA256"] = String(repeating: "0", count: 64)
                    root["envelopes"] = envelopes
                },
                .previousDigestMismatch(sequence: 1)
            ),
            (
                "tail",
                { root in
                    var cursor = try XCTUnwrap(root["cursor"] as? [String: Any])
                    cursor["tailDigest"] = String(repeating: "0", count: 64)
                    root["cursor"] = cursor
                },
                .cursorMismatch
            ),
            (
                "document",
                { root in
                    root["documentDigest"] = String(repeating: "0", count: 64)
                },
                .documentDigestMismatch
            ),
            (
                "genesis",
                { root in
                    var genesis = try XCTUnwrap(root["genesis"] as? [String: Any])
                    genesis["direction"] = "outgoing"
                    root["genesis"] = genesis
                },
                .genesisDigestMismatch
            ),
        ]

        for (name, mutate, expectedError) in cases {
            var root = try journalJSONObject(journal)
            try mutate(&root)
            XCTAssertThrowsError(
                try pinnedDecoder().decode(
                    CompetitionJournal.self,
                    from: JSONSerialization.data(withJSONObject: root)
                ),
                name
            ) { error in
                XCTAssertEqual(error as? CompetitionJournalError, expectedError, name)
            }
        }
    }

    func testTamperedSequenceAndEnvelopeDigestAreRejected() throws {
        let journal = try acceptedJournal()
        var sequenceRoot = try journalJSONObject(journal)
        var sequenceEnvelopes = try XCTUnwrap(
            sequenceRoot["envelopes"] as? [[String: Any]]
        )
        sequenceEnvelopes[0]["sequence"] = 2
        sequenceRoot["envelopes"] = sequenceEnvelopes
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                CompetitionJournal.self,
                from: JSONSerialization.data(withJSONObject: sequenceRoot)
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .sequenceViolation(expected: 1, found: 2)
            )
        }

        var digestRoot = try journalJSONObject(journal)
        var digestEnvelopes = try XCTUnwrap(
            digestRoot["envelopes"] as? [[String: Any]]
        )
        digestEnvelopes[0]["envelopeSHA256"] = String(repeating: "0", count: 64)
        digestRoot["envelopes"] = digestEnvelopes
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                CompetitionJournal.self,
                from: JSONSerialization.data(withJSONObject: digestRoot)
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .cursorMismatch
            )
        }
    }

    func testUnsupportedEnvelopeAndPayloadVersionsAreUpgradeRequiredAndPayloadStaysOpaque() throws {
        let journal = try acceptedJournal()
        for (field, expectedError) in [
            (
                "envelopeVersion",
                CompetitionJournalError.upgradeRequiredEnvelopeVersion(
                    sequence: 1,
                    found: 999
                )
            ),
            (
                "payloadVersion",
                CompetitionJournalError.upgradeRequiredPayloadVersion(
                    sequence: 1,
                    found: 999
                )
            ),
        ] {
            var root = try journalJSONObject(journal)
            var envelopes = try XCTUnwrap(root["envelopes"] as? [[String: Any]])
            let originalPayload = try XCTUnwrap(envelopes[0]["payload"] as? String)
            envelopes[0][field] = 999
            root["envelopes"] = envelopes
            let data = try JSONSerialization.data(withJSONObject: root)

            XCTAssertThrowsError(
                try pinnedDecoder().decode(CompetitionJournal.self, from: data)
            ) { error in
                XCTAssertEqual(error as? CompetitionJournalError, expectedError)
            }
            let preservedRoot = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let preservedEnvelopes = try XCTUnwrap(
                preservedRoot["envelopes"] as? [[String: Any]]
            )
            XCTAssertEqual(preservedEnvelopes[0]["payload"] as? String, originalPayload)
        }
    }

    func testFutureEnvelopeAndPayloadVersionsPrecedeCurrentShapeDecoding() throws {
        let journal = try acceptedJournal()

        var futureEnvelopeRoot = try journalJSONObject(journal)
        var futureEnvelopeRecords = try XCTUnwrap(
            futureEnvelopeRoot["envelopes"] as? [[String: Any]]
        )
        futureEnvelopeRecords[0]["envelopeVersion"] = 999
        futureEnvelopeRecords[0].removeValue(forKey: "sequence")
        futureEnvelopeRecords[0].removeValue(forKey: "payload")
        futureEnvelopeRoot["envelopes"] = futureEnvelopeRecords
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                CompetitionJournal.self,
                from: JSONSerialization.data(withJSONObject: futureEnvelopeRoot)
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .upgradeRequiredEnvelopeVersion(
                    sequence: CompetitionJournalEnvelope.unknownSequence,
                    found: 999
                )
            )
        }

        var futurePayloadRoot = try journalJSONObject(journal)
        var futurePayloadRecords = try XCTUnwrap(
            futurePayloadRoot["envelopes"] as? [[String: Any]]
        )
        futurePayloadRecords[0]["payloadVersion"] = 999
        futurePayloadRecords[0].removeValue(forKey: "payload")
        futurePayloadRoot["envelopes"] = futurePayloadRecords
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                CompetitionJournal.self,
                from: JSONSerialization.data(withJSONObject: futurePayloadRoot)
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .upgradeRequiredPayloadVersion(sequence: 1, found: 999)
            )
        }
    }

    func testPayloadVersionMayUpgradeFromV1ButCannotDowngradeAfterV2() throws {
        let source = try acceptedJournal()
        let projection = try CompetitionReplayer.replay(source)
        let started = try XCTUnwrap(
            engine.observeClock(
                projection.competition,
                at: date(2026, 8, 10, 0)
            ).first
        )
        let legacyPayload = try pinnedEncoder().encode(
            LegacyCompetitionDomainEventV1.lifecycle(started)
        )
        let downgradedEnvelope = CompetitionJournalEnvelope(
            payloadVersion: 1,
            commitRevision: source.cursor.commitRevision + 1,
            sequence: source.cursor.eventCount + 1,
            streamID: competitionID,
            semanticEventID: started.id,
            payload: legacyPayload,
            previousEnvelopeSHA256: source.cursor.tailDigest
        )

        XCTAssertThrowsError(
            try CompetitionJournal(
                validating: source.genesis,
                envelopes: source.envelopes + [downgradedEnvelope]
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .payloadVersionDowngrade(sequence: downgradedEnvelope.sequence)
            )
        }
    }

    func testPayloadV2RejectsStandaloneSnapshotPoisonBeforeBoundFinalRead() throws {
        var journal = try tallyingJournal()
        let cursorBeforePoison = journal.cursor
        let poison = try ActivitySnapshotRecorded(
            observationID: "unbound-day-seven-poison",
            competitionID: competitionID,
            observedAt: date(2026, 8, 10, 12),
            dayOrdinal: 7,
            snapshot: try snapshot(points: 600)
        )

        XCTAssertThrowsError(
            try journal.append(
                [.activitySnapshotRecorded(poison)],
                expectedCursor: cursorBeforePoison
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .standaloneActivitySnapshotRequiresPayloadV1(
                    sequence: cursorBeforePoison.eventCount + 1
                )
            )
        }
        XCTAssertEqual(journal.cursor, cursorBeforePoison)

        let projection = try CompetitionReplayer.replay(journal)
        let refresh = try refreshAttempt(
            in: projection,
            attemptID: "bound-all-one-hundred",
            ordinal: 1,
            attemptedAt: date(2026, 8, 17, 0),
            readAt: date(2026, 8, 17, 0, 1),
            trigger: .reconciliationProbe,
            availability: { _ in
                .observed(try self.snapshot(points: 100))
            }
        )
        let finalRead = try engine.recordFinalRead(
            projection.competition,
            evidence: try projection.finalReadEvidence(after: refresh)
        )
        _ = try journal.append(
            [
                .activityRefreshAttemptRecorded(refresh),
                .lifecycle(finalRead),
            ],
            expectedCursor: journal.cursor
        )

        let replayed = try CompetitionReplayer.replay(journal)
        XCTAssertEqual(
            replayed.scoreLedger.entry(forDayOrdinal: 7)?
                .acceptedScore?.points,
            100
        )
    }

    func testSemanticallyValidHashesStillRejectCrossStreamIdentityDuplicateAndTransition() throws {
        let genesis = try makeGenesis(expiresAt: nil)
        let empty = try CompetitionJournal(genesis: genesis)
        let acceptance = try acceptanceEvent()
        let payload = try pinnedEncoder().encode(
            CompetitionDomainEvent.lifecycle(acceptance)
        )
        let otherID = CompetitionID(
            UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        )
        let crossStream = CompetitionJournalEnvelope(
            commitRevision: 1,
            sequence: 1,
            streamID: otherID,
            semanticEventID: acceptance.id,
            payload: payload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        XCTAssertThrowsError(
            try CompetitionJournal(validating: genesis, envelopes: [crossStream])
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .streamMismatch(sequence: 1)
            )
        }

        let wrongIdentity = CompetitionJournalEnvelope(
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: "wrong-but-well-hashed",
            payload: payload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        XCTAssertThrowsError(
            try CompetitionJournal(validating: genesis, envelopes: [wrongIdentity])
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .envelopeIdentityMismatch(sequence: 1)
            )
        }

        let first = CompetitionJournalEnvelope(
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: acceptance.id,
            payload: payload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        let duplicate = CompetitionJournalEnvelope(
            commitRevision: 1,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: acceptance.id,
            payload: payload,
            previousEnvelopeSHA256: first.envelopeSHA256
        )
        XCTAssertThrowsError(
            try CompetitionJournal(validating: genesis, envelopes: [first, duplicate])
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .duplicatePersistedSemanticEventID(eventID: acceptance.id)
            )
        }

        let invalidEvent = CompetitionEvent(
            competitionID: competitionID,
            occurredAt: date(2026, 8, 9, 11),
            kind: .competitionArchived
        )
        let invalidPayload = try pinnedEncoder().encode(
            CompetitionDomainEvent.lifecycle(invalidEvent)
        )
        let invalidTransition = CompetitionJournalEnvelope(
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: invalidEvent.id,
            payload: invalidPayload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        XCTAssertThrowsError(
            try CompetitionJournal(
                validating: genesis,
                envelopes: [invalidTransition]
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .invalidDomainTransition(sequence: 1)
            )
        }
    }

    func testSemanticallyValidHashesStillRejectSequenceAndCommitRevisionGaps() throws {
        let genesis = try makeGenesis(expiresAt: nil)
        let empty = try CompetitionJournal(genesis: genesis)
        let acceptance = try acceptanceEvent()
        let payload = try pinnedEncoder().encode(
            CompetitionDomainEvent.lifecycle(acceptance)
        )
        let sequenceGap = CompetitionJournalEnvelope(
            commitRevision: 1,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: acceptance.id,
            payload: payload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        XCTAssertThrowsError(
            try CompetitionJournal(validating: genesis, envelopes: [sequenceGap])
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .sequenceViolation(expected: 1, found: 2)
            )
        }

        let revisionGap = CompetitionJournalEnvelope(
            commitRevision: 2,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: acceptance.id,
            payload: payload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        XCTAssertThrowsError(
            try CompetitionJournal(validating: genesis, envelopes: [revisionGap])
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .commitRevisionViolation(sequence: 1)
            )
        }
    }

    func testAcceptanceAndFinalReadSameSemanticIDDivergenceAreConflicts() throws {
        var acceptanceJournal = try CompetitionJournal(
            genesis: makeGenesis(expiresAt: nil)
        )
        let firstAcceptance = try acceptanceEvent()
        let pending = acceptanceJournal.genesis.makeCompetition()
        let differentPlanAcceptance = try engine.accept(
            pending,
            at: firstAcceptance.occurredAt,
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: OpponentPlanGenerationRequest(
                seed: 999,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
        _ = try acceptanceJournal.append(
            [.lifecycle(firstAcceptance)],
            expectedCursor: acceptanceJournal.cursor
        )
        XCTAssertThrowsError(
            try acceptanceJournal.append(
                [.lifecycle(differentPlanAcceptance)],
                expectedCursor: acceptanceJournal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .semanticEventConflict(eventID: firstAcceptance.id)
            )
        }

        var finalReadJournal = try tallyingJournal()
        finalReadJournal = try journalWithSevenOwnerDays(
            from: finalReadJournal
        ) { _ in 300 }
        let projection = try CompetitionReplayer.replay(finalReadJournal)
        let firstEvidence = try completeEvidence(
            attemptID: "same-final-attempt",
            ordinals: Set(1...7),
            projection: projection
        )
        let firstFinalRead = try engine.recordFinalRead(
            projection.competition,
            evidence: firstEvidence
        )
        let firstRefresh = try refreshBound(to: firstEvidence, in: projection)
        _ = try finalReadJournal.append(
            [
                .activityRefreshAttemptRecorded(firstRefresh),
                .lifecycle(firstFinalRead),
            ],
            expectedCursor: finalReadJournal.cursor
        )
        let changedEvidence = try FinalReadEvidence(
            attemptID: firstEvidence.attemptID,
            readAt: firstEvidence.readAt.addingTimeInterval(1),
            monotonicInstant: firstEvidence.monotonicInstant,
            evaluableOrdinals: firstEvidence.evaluableOrdinals,
            acceptedScoreOrdinals: firstEvidence.acceptedScoreOrdinals,
            missingOrdinals: firstEvidence.missingOrdinals,
            unavailableOrdinals: firstEvidence.unavailableOrdinals,
            completeWindowContent: firstEvidence.completeWindowContent,
            opponentPlanIsFinal: firstEvidence.opponentPlanIsFinal
        )
        let changedFinalRead = try engine.recordFinalRead(
            projection.competition,
            evidence: changedEvidence
        )
        XCTAssertThrowsError(
            try finalReadJournal.append(
                [.lifecycle(changedFinalRead)],
                expectedCursor: finalReadJournal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .semanticEventConflict(eventID: firstFinalRead.id)
            )
        }
    }

    func testSignedZeroEquivalentRefreshIsAnExactDuplicate() throws {
        var journal = try acceptedJournal()
        let projection = try CompetitionReplayer.replay(journal)
        let positive = try dayOneRefresh(
            in: projection,
            attemptID: "signed-zero",
            ordinal: 1,
            readAt: date(2026, 8, 10, 8),
            snapshot: try snapshot(points: 0.0)
        )
        let negative = try dayOneRefresh(
            in: projection,
            attemptID: "signed-zero",
            ordinal: 1,
            readAt: date(2026, 8, 10, 8),
            snapshot: ActivitySnapshot(
                moveMode: .activeEnergyKilocalories,
                standMode: .standHours,
                move: try ActivityRingReading(value: -0.0, goal: 1),
                exercise: try ActivityRingReading(value: -0.0, goal: 1),
                standOrRoll: try ActivityRingReading(value: -0.0, goal: 1),
                isPaused: false
            )
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(positive)],
            expectedCursor: journal.cursor
        )
        let before = journal

        let result = try journal.append(
            [.activityRefreshAttemptRecorded(negative)],
            expectedCursor: try CompetitionJournal(genesis: makeGenesis(expiresAt: nil)).cursor
        )

        XCTAssertEqual(result.appendedCount, 0)
        XCTAssertEqual(journal, before)
    }

    func testFinalizationRejectsOwnerRevisionAfterItsEligibleRead() throws {
        var journal = try stableReadJournal { _, _ in 300 }
        let stableProjection = try CompetitionReplayer.replay(journal)
        let policy = FinalizationPolicy(
            minimumStabilityNanoseconds: 1_000,
            bestAvailableDeadline: date(2026, 8, 18, 0)
        )
        guard case let .finalize(authorization) = policy.decision(
            for: stableProjection.competition,
            at: date(2026, 8, 17, 0, 3)
        ) else {
            return XCTFail("Fixture must have a stable authorization")
        }
        let lateWatchRevision = try refreshAttempt(
            in: stableProjection,
            attemptID: "late-after-eligible-read",
            ordinal: stableProjection.activityRefresh.nextAttemptOrdinal,
            readAt: date(2026, 8, 17, 0, 4),
            trigger: .summaryUpdate,
            availability: { ordinal in
                if ordinal == 1 {
                    return .observed(try self.snapshot(points: 500))
                }
                return .observed(
                    try XCTUnwrap(
                        stableProjection.scoreLedger.entry(
                            forDayOrdinal: ordinal
                        )?.latestEvidence.snapshot
                    )
                )
            }
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(lateWatchRevision)],
            expectedCursor: journal.cursor
        )
        let revisedProjection = try CompetitionReplayer.replay(journal)
        let staleFinalization = try engine.finalize(
            revisedProjection.competition,
            authorization: authorization,
            at: date(2026, 8, 17, 0, 5)
        )
        let before = journal

        XCTAssertThrowsError(
            try journal.append(
                [.lifecycle(staleFinalization)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .ownerWindowMismatch(sequence: before.cursor.eventCount + 1)
            )
        }
        XCTAssertEqual(journal, before)
    }

    func testBestAvailableFinalizationReplaysAndFreezesAtDeadline() throws {
        var journal = try tallyingJournal()
        journal = try journalWithSevenOwnerDays(from: journal) { _ in 250 }
        let projection = try CompetitionReplayer.replay(journal)
        let evidence = try FinalReadEvidence(
            attemptID: "best-available-only-read",
            readAt: date(2026, 8, 17, 0, 1),
            monotonicInstant: MonotonicInstant(
                epochID: "best-available",
                nanoseconds: 9_007_199_254_740_993
            ),
            evaluableOrdinals: Set(1...7),
            acceptedScoreOrdinals: Set(1...7),
            missingOrdinals: [],
            unavailableOrdinals: [],
            completeWindowContent: try completeContent(for: projection),
            opponentPlanIsFinal: true
        )
        let read = try engine.recordFinalRead(
            projection.competition,
            evidence: evidence
        )
        let refresh = try refreshBound(to: evidence, in: projection)
        _ = try journal.append(
            [
                .activityRefreshAttemptRecorded(refresh),
                .lifecycle(read),
            ],
            expectedCursor: journal.cursor
        )
        let afterRead = try CompetitionReplayer.replay(journal)
        let policy = FinalizationPolicy(
            minimumStabilityNanoseconds: UInt64.max,
            bestAvailableDeadline: date(2026, 8, 17, 0, 2)
        )
        guard case let .finalize(authorization) = policy.decision(
            for: afterRead.competition,
            at: date(2026, 8, 17, 0, 2)
        ) else {
            return XCTFail("Deadline must authorize best available")
        }
        let finalization = try engine.finalize(
            afterRead.competition,
            authorization: authorization,
            at: date(2026, 8, 17, 0, 2)
        )
        _ = try journal.append(
            [.lifecycle(finalization)],
            expectedCursor: journal.cursor
        )

        let completed = try CompetitionReplayer.replay(journal)
        guard case let .completed(value) = completed.competition.lifecycle else {
            return XCTFail("Best available must replay completed")
        }
        XCTAssertEqual(value.basis, .bestAvailable)
        XCTAssertTrue(completed.scoreLedger.isFrozen)

        let roundTrip = try pinnedDecoder().decode(
            CompetitionJournal.self,
            from: pinnedEncoder().encode(journal)
        )
        guard case let .completed(roundTripped) = try CompetitionReplayer
            .replay(roundTrip).competition.lifecycle
        else {
            return XCTFail("Round-trip must remain completed")
        }
        XCTAssertEqual(roundTripped.basis, .bestAvailable)
    }

    func testSequenceAndCommitRevisionOverflowReturnErrorsInsteadOfTrapping() throws {
        let validDigest = String(repeating: "0", count: 64)
        let sequenceAtMaximum = CompetitionJournalCursor(
            commitRevision: 1,
            eventCount: UInt64.max,
            tailDigest: validDigest
        )
        XCTAssertThrowsError(
            try CompetitionJournal.validatedAppendCoordinates(
                after: sequenceAtMaximum,
                newEventCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .sequenceOverflow
            )
        }

        let revisionAtMaximum = CompetitionJournalCursor(
            commitRevision: UInt64.max,
            eventCount: 1,
            tailDigest: validDigest
        )
        XCTAssertThrowsError(
            try CompetitionJournal.validatedAppendCoordinates(
                after: revisionAtMaximum,
                newEventCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .commitRevisionOverflow
            )
        }
    }

    func testGenesisAndPayloadV1GoldenDigestsPinDatesScoringAndNestedPlanJSON() throws {
        let journal = try CompetitionJournal(genesis: makeGenesis())
        XCTAssertEqual(
            journal.genesisDigest,
            "7fd1bf3a159a407acd444e4e4505095fc98fe409e26882aed70b178afe605f3f"
        )

        let accepted = try acceptedJournal()
        XCTAssertEqual(
            accepted.envelopes.first?.payloadSHA256,
            "cb87606b6978caaa0fffe954c8a7393f0dcc741dffa4fda97420dc05b15ca43a"
        )
    }

    func testCompetitionEventKindDiscriminatorKeysRemainExact() throws {
        let completed = try completedJournal { _, opponentPoints in
            opponentPoints
        }
        var kinds = try CompetitionReplayer.decodedEvents(in: completed)
            .compactMap { event -> CompetitionEventKind? in
                guard case let .lifecycle(lifecycle) = event else {
                    return nil
                }
                return lifecycle.kind
            }
        kinds.append(contentsOf: [
            .invitationDeclined,
            .invitationExpired,
            .competitionArchived,
        ])

        let keys = try Set(kinds.map { kind -> String in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: pinnedEncoder().encode(kind)
                ) as? [String: Any]
            )
            XCTAssertEqual(object.keys.count, 1)
            return try XCTUnwrap(object.keys.first)
        })

        XCTAssertEqual(
            keys,
            [
                "invitationAccepted",
                "invitationDeclined",
                "invitationExpired",
                "competitionStarted",
                "dayClosed",
                "finalDayStarted",
                "tallyStarted",
                "finalReadRecorded",
                "competitionFinalized",
                "competitionArchived",
            ]
        )
    }

    func testJournalMapsInvalidRecordedSnapshotPayloadPrecisely() throws {
        let accepted = try acceptedJournal()
        let validObservation = try observation(
            id: "decode-source-check",
            at: date(2026, 8, 10, 8),
            points: 100
        )
        var payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: pinnedEncoder().encode(
                    CompetitionDomainEvent.activitySnapshotRecorded(
                        validObservation
                    )
                )
            ) as? [String: Any]
        )
        var caseObject = try XCTUnwrap(
            payloadObject["activitySnapshotRecorded"] as? [String: Any]
        )
        var eventObject = try XCTUnwrap(caseObject["_0"] as? [String: Any])
        eventObject["dayOrdinal"] = 8
        caseObject["_0"] = eventObject
        payloadObject["activitySnapshotRecorded"] = caseObject
        let invalidPayload = try JSONSerialization.data(
            withJSONObject: payloadObject,
            options: [.sortedKeys]
        )
        let envelope = CompetitionJournalEnvelope(
            commitRevision: accepted.cursor.commitRevision + 1,
            sequence: accepted.cursor.eventCount + 1,
            streamID: competitionID,
            semanticEventID: validObservation.semanticEventID,
            payload: invalidPayload,
            previousEnvelopeSHA256: accepted.cursor.tailDigest
        )

        XCTAssertThrowsError(
            try CompetitionJournal(
                validating: accepted.genesis,
                envelopes: accepted.envelopes + [envelope]
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .invalidActivityObservation(sequence: envelope.sequence)
            )
        }
    }

    func testUnsupportedGenesisVersionAndMalformedDigestAreClassifiedPrecisely() throws {
        let journal = try CompetitionJournal(genesis: makeGenesis())
        var futureGenesis = try journalJSONObject(journal)
        var genesis = try XCTUnwrap(futureGenesis["genesis"] as? [String: Any])
        genesis["version"] = 999
        futureGenesis["genesis"] = genesis
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                CompetitionJournal.self,
                from: JSONSerialization.data(withJSONObject: futureGenesis)
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .upgradeRequiredGenesisVersion(found: 999)
            )
        }

        var malformed = try journalJSONObject(journal)
        malformed["documentDigest"] = "not-sha-256"
        XCTAssertThrowsError(
            try pinnedDecoder().decode(
                CompetitionJournal.self,
                from: JSONSerialization.data(withJSONObject: malformed)
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .malformedDigest(field: "documentDigest")
            )
        }
    }

    func testRefreshAttemptRequiresExactOrderedPartitionAndHonestSourceStatus() throws {
        let projection = try CompetitionReplayer.replay(acceptedJournal())
        let validDays = try refreshDays(in: projection) { ordinal in
            .observed(try snapshot(points: Double(ordinal * 50)))
        }

        XCTAssertThrowsError(
            try ActivityRefreshAttemptRecorded(
                attemptID: "attempt-partition-short",
                competitionID: competitionID,
                attemptOrdinal: 1,
                trigger: .foreground,
                attemptedAt: date(2026, 8, 10, 11, 59),
                readAt: date(2026, 8, 10, 12),
                monotonicInstant: MonotonicInstant(
                    epochID: "boot-a",
                    nanoseconds: 1
                ),
                readStatus: .completed,
                days: Array(validDays.dropLast())
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivityRefreshAttemptRecorded.ValidationError,
                .invalidDayPartition
            )
        }

        var outOfOrder = validDays
        outOfOrder.swapAt(0, 1)
        XCTAssertThrowsError(
            try ActivityRefreshAttemptRecorded(
                attemptID: "attempt-partition-order",
                competitionID: competitionID,
                attemptOrdinal: 1,
                trigger: .foreground,
                attemptedAt: date(2026, 8, 10, 11, 59),
                readAt: date(2026, 8, 10, 12),
                monotonicInstant: MonotonicInstant(
                    epochID: "boot-a",
                    nanoseconds: 1
                ),
                readStatus: .completed,
                days: outOfOrder
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivityRefreshAttemptRecorded.ValidationError,
                .invalidDayPartition
            )
        }

        var duplicateDayIdentity = validDays
        duplicateDayIdentity[1] = ActivityDayObservation(
            day: duplicateDayIdentity[0].day,
            ordinal: 2,
            availability: duplicateDayIdentity[1].availability
        )
        XCTAssertThrowsError(
            try ActivityRefreshAttemptRecorded(
                attemptID: "attempt-duplicate-day",
                competitionID: competitionID,
                attemptOrdinal: 1,
                trigger: .foreground,
                attemptedAt: date(2026, 8, 10, 11, 59),
                readAt: date(2026, 8, 10, 12),
                monotonicInstant: MonotonicInstant(
                    epochID: "boot-a",
                    nanoseconds: 1
                ),
                readStatus: .completed,
                days: duplicateDayIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivityRefreshAttemptRecorded.ValidationError,
                .duplicateCompetitionDay
            )
        }

        XCTAssertThrowsError(
            try refreshAttempt(
                in: projection,
                attemptID: "attempt-backwards-time",
                ordinal: 1,
                attemptedAt: date(2026, 8, 10, 12, 1),
                readAt: date(2026, 8, 10, 12)
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivityRefreshAttemptRecorded.ValidationError,
                .readPrecedesAttempt
            )
        }

        XCTAssertThrowsError(
            try refreshAttempt(
                in: projection,
                attemptID: "attempt-failed-with-data",
                ordinal: 1,
                readStatus: .failed(reason: .protectedDataUnavailable)
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivityRefreshAttemptRecorded.ValidationError,
                .failedReadContainsSourceData
            )
        }

        let failed = try refreshAttempt(
            in: projection,
            attemptID: "attempt-private-reason",
            ordinal: 1,
            readStatus: .failed(reason: .protectedDataUnavailable),
            availability: { _ in
                .unavailable(reason: .sourceDataUnavailable)
            }
        )
        let encoded = String(
            decoding: try pinnedEncoder().encode(failed),
            as: UTF8.self
        )
        XCTAssertTrue(encoded.contains("protectedDataUnavailable"))
        XCTAssertTrue(encoded.contains("sourceDataUnavailable"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("denied"))
        XCTAssertFalse(encoded.contains("NS"))

        let invalidResponse = try refreshAttempt(
            in: projection,
            attemptID: "attempt-invalid-response",
            ordinal: 1,
            readStatus: .failed(reason: .invalidResponse),
            availability: { _ in
                .unavailable(reason: .invalidSourceData)
            }
        )
        let invalidResponseData = try pinnedEncoder().encode(invalidResponse)
        XCTAssertEqual(
            try pinnedDecoder().decode(
                ActivityRefreshAttemptRecorded.self,
                from: invalidResponseData
            ),
            invalidResponse
        )
        let invalidResponseJSON = String(
            decoding: invalidResponseData,
            as: UTF8.self
        )
        XCTAssertTrue(invalidResponseJSON.contains("invalidResponse"))
        XCTAssertTrue(invalidResponseJSON.contains("invalidSourceData"))
        XCTAssertFalse(
            invalidResponseJSON.localizedCaseInsensitiveContains("denied")
        )
    }

    func testRefreshReplayDerivesLedgerAndDurableAttemptProjection() throws {
        var journal = try tallyingJournal()
        let before = try CompetitionReplayer.replay(journal)
        let refresh = try refreshAttempt(
            in: before,
            attemptID: "attempt-full-1",
            ordinal: 1,
            readAt: date(2026, 8, 17, 0, 1),
            availability: { ordinal in
                .observed(try self.snapshot(points: Double(ordinal * 50)))
            }
        )

        _ = try journal.append(
            [.activityRefreshAttemptRecorded(refresh)],
            expectedCursor: journal.cursor
        )
        let roundTripped = try pinnedDecoder().decode(
            CompetitionJournal.self,
            from: pinnedEncoder().encode(journal)
        )
        let replayed = try CompetitionReplayer.replay(roundTripped)

        XCTAssertEqual(journal.envelopes.last?.payloadVersion, 4)
        XCTAssertEqual(replayed.activityRefresh.latestAttempt, refresh)
        XCTAssertEqual(
            replayed.activityRefresh.lastSuccessfulFullWindowRefreshAt,
            refresh.readAt
        )
        XCTAssertEqual(replayed.activityRefresh.nextAttemptOrdinal, 2)
        for ordinal in 1...7 {
            XCTAssertEqual(
                replayed.scoreLedger.entry(forDayOrdinal: ordinal)?
                    .acceptedScore?.points,
                Double(ordinal * 50)
            )
        }
    }

    func testRefreshIDDuplicateConflictAndAttemptOrdinalsAreReplayValidated() throws {
        var journal = try tallyingJournal()
        let staleCursor = journal.cursor
        let projection = try CompetitionReplayer.replay(journal)
        let first = try refreshAttempt(
            in: projection,
            attemptID: "cas-stable-attempt",
            ordinal: 1,
            readAt: date(2026, 8, 17, 0, 1)
        )
        XCTAssertEqual(
            first.semanticEventID,
            "activity-refresh-attempt-recorded:v1:11111111-2222-3333-4444-555555555555:attempt:1"
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(first)],
            expectedCursor: journal.cursor
        )
        let committedBytes = try pinnedEncoder().encode(journal)

        let retry = try journal.append(
            [.activityRefreshAttemptRecorded(first)],
            expectedCursor: staleCursor
        )
        XCTAssertEqual(retry.appendedCount, 0)
        XCTAssertEqual(try pinnedEncoder().encode(journal), committedBytes)

        let conflicting = try refreshAttempt(
            in: projection,
            attemptID: "different-attempt-same-ordinal",
            ordinal: 1,
            readAt: date(2026, 8, 17, 0, 1),
            trigger: .pullToRefresh
        )
        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(conflicting)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .semanticEventConflict(eventID: first.semanticEventID)
            )
        }

        let afterFirst = try CompetitionReplayer.replay(journal)
        let skipped = try refreshAttempt(
            in: afterFirst,
            attemptID: "attempt-skipped-to-three",
            ordinal: 3,
            readAt: date(2026, 8, 17, 0, 2)
        )
        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(skipped)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .activityRefreshAttemptOrdinalViolation(expected: 2, found: 3)
            )
        }
        XCTAssertEqual(try pinnedEncoder().encode(journal), committedBytes)

        let reusedAttemptID = try refreshAttempt(
            in: afterFirst,
            attemptID: first.attemptID,
            ordinal: 2,
            readAt: date(2026, 8, 17, 0, 2)
        )
        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(reusedAttemptID)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .duplicateActivityRefreshAttemptID(first.attemptID)
            )
        }
    }

    func testRefreshProjectionOverflowIsNonMutatingAndRepeatable() throws {
        let replayed = try CompetitionReplayer.replay(tallyingJournal())
        let attempt = try ActivityRefreshAttemptRecorded(
            attemptID: "attempt-ordinal-max",
            competitionID: competitionID,
            attemptOrdinal: .max,
            trigger: .reconciliationProbe,
            attemptedAt: date(2026, 8, 17, 0),
            readAt: date(2026, 8, 17, 0, 1),
            monotonicInstant: MonotonicInstant(
                epochID: "boot-overflow",
                nanoseconds: 1
            ),
            readStatus: .completed,
            days: try refreshDays(in: replayed) { _ in
                .observed(try self.snapshot(points: 300))
            }
        )
        var projection = ActivityRefreshProjection()
        projection.nextAttemptOrdinal = .max
        let before = projection

        for _ in 0..<2 {
            XCTAssertThrowsError(try projection.record(attempt)) { error in
                XCTAssertEqual(
                    error as? ActivityRefreshProjectionError,
                    .ordinalOverflow
                )
            }
            XCTAssertEqual(projection, before)
        }
    }

    func testMissingAndFailedRefreshesPreserveAcceptedScoresAndSuccessTimestamp() throws {
        var journal = try tallyingJournal()
        let initial = try CompetitionReplayer.replay(journal)
        let full = try refreshAttempt(
            in: initial,
            attemptID: "attempt-preserve-1",
            ordinal: 1,
            readAt: date(2026, 8, 17, 0, 1),
            availability: { _ in .observed(try self.snapshot(points: 300)) }
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(full)],
            expectedCursor: journal.cursor
        )

        let afterFull = try CompetitionReplayer.replay(journal)
        let partial = try refreshAttempt(
            in: afterFull,
            attemptID: "attempt-preserve-2",
            ordinal: 2,
            readAt: date(2026, 8, 17, 0, 2),
            availability: { ordinal in
                if ordinal == 1 { return .missing }
                if ordinal == 2 {
                    return .unavailable(reason: .sourceDataUnavailable)
                }
                return .observed(try self.snapshot(points: 250))
            }
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(partial)],
            expectedCursor: journal.cursor
        )

        let afterPartial = try CompetitionReplayer.replay(journal)
        let failed = try refreshAttempt(
            in: afterPartial,
            attemptID: "attempt-preserve-3",
            ordinal: 3,
            readAt: date(2026, 8, 17, 0, 3),
            readStatus: .failed(reason: .protectedDataUnavailable),
            availability: { _ in
                .unavailable(reason: .sourceDataUnavailable)
            }
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(failed)],
            expectedCursor: journal.cursor
        )
        let replayed = try CompetitionReplayer.replay(journal)

        XCTAssertEqual(replayed.activityRefresh.latestAttempt, failed)
        XCTAssertEqual(
            replayed.activityRefresh.lastSuccessfulFullWindowRefreshAt,
            partial.readAt
        )
        XCTAssertEqual(replayed.activityRefresh.nextAttemptOrdinal, 4)
        for ordinal in 1...7 {
            XCTAssertEqual(
                replayed.scoreLedger.entry(forDayOrdinal: ordinal)?
                    .acceptedScore?.points,
                300
            )
        }
    }

    func testRefreshReplayRejectsCompetitionDayThatDoesNotMatchScheduleOrdinal() throws {
        var journal = try acceptedJournal()
        let projection = try CompetitionReplayer.replay(journal)
        var days = try refreshDays(in: projection) { _ in
            .observed(try snapshot(points: 300))
        }
        let schedule = try XCTUnwrap(projection.competition.schedule)
        days[0] = ActivityDayObservation(
            day: try schedule.calendar.day(after: days[6].day),
            ordinal: 1,
            availability: days[0].availability
        )
        let mismatched = try ActivityRefreshAttemptRecorded(
            attemptID: "attempt-day-mismatch",
            competitionID: competitionID,
            attemptOrdinal: 1,
            trigger: .foreground,
            attemptedAt: date(2026, 8, 10, 11, 59),
            readAt: date(2026, 8, 10, 12),
            monotonicInstant: MonotonicInstant(
                epochID: "boot-a",
                nanoseconds: 1
            ),
            readStatus: .completed,
            days: days
        )

        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(mismatched)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .activityRefreshDayMismatch(ordinal: 1)
            )
        }
    }

    func testRefreshReplayRejectsNotYetOccurredAfterStoredDayStart() throws {
        var journal = try tallyingJournal()
        let projection = try CompetitionReplayer.replay(journal)
        let impossible = try refreshAttempt(
            in: projection,
            attemptID: "attempt-impossible-future-day",
            ordinal: 1,
            attemptedAt: date(2026, 8, 17, 0),
            readAt: date(2026, 8, 17, 0, 1),
            availability: { _ in .notYetOccurred }
        )

        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(impossible)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .activityRefreshAvailabilityMismatch(ordinal: 1)
            )
        }
    }

    func testRefreshReplayRejectsClaimedAvailabilityBeforeStoredDayStart() throws {
        var journal = try acceptedJournal()
        let projection = try CompetitionReplayer.replay(journal)
        let valid = try refreshAttempt(
            in: projection,
            attemptID: "attempt-current-day-only",
            ordinal: 1,
            attemptedAt: date(2026, 8, 10, 11, 59),
            readAt: date(2026, 8, 10, 12),
            availability: { ordinal in
                ordinal == 1
                    ? .observed(try self.snapshot(points: 300))
                    : .notYetOccurred
            }
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(valid)],
            expectedCursor: journal.cursor
        )

        let afterValid = try CompetitionReplayer.replay(journal)
        XCTAssertEqual(
            afterValid.scoreLedger.entry(forDayOrdinal: 1)?
                .acceptedScore?.points,
            300
        )
        XCTAssertNil(afterValid.scoreLedger.entry(forDayOrdinal: 2))

        let impossible = try refreshAttempt(
            in: afterValid,
            attemptID: "attempt-future-day-data",
            ordinal: 2,
            attemptedAt: date(2026, 8, 10, 12),
            readAt: date(2026, 8, 10, 12, 1),
            availability: { ordinal in
                if ordinal == 1 {
                    return .observed(try self.snapshot(points: 300))
                }
                if ordinal == 2 { return .missing }
                return .notYetOccurred
            }
        )

        XCTAssertThrowsError(
            try journal.append(
                [.activityRefreshAttemptRecorded(impossible)],
                expectedCursor: journal.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .activityRefreshAvailabilityMismatch(ordinal: 2)
            )
        }
    }

    func testTallyFinalReadMustBeBoundToImmediatelyPrecedingRefreshInSameCommit() throws {
        let source = try tallyingJournal()
        let projection = try CompetitionReplayer.replay(source)
        let refresh = try refreshAttempt(
            in: projection,
            attemptID: "tally-source-attempt-1",
            ordinal: 1,
            attemptedAt: date(2026, 8, 17, 0),
            readAt: date(2026, 8, 17, 0, 1),
            trigger: .reconciliationProbe,
            availability: { _ in .observed(try self.snapshot(points: 300)) }
        )
        let evidence = try projection.finalReadEvidence(after: refresh)
        let finalRead = try engine.recordFinalRead(
            projection.competition,
            evidence: evidence
        )

        var atomic = source
        _ = try atomic.append(
            [
                .activityRefreshAttemptRecorded(refresh),
                .lifecycle(finalRead),
            ],
            expectedCursor: atomic.cursor
        )
        guard case let .tallying(tally) = try CompetitionReplayer
            .replay(atomic).competition.lifecycle
        else {
            return XCTFail("Bound final read must replay into tally evidence")
        }
        XCTAssertEqual(tally.reconciliation.latestAttempt, evidence)

        var separated = source
        _ = try separated.append(
            [.activityRefreshAttemptRecorded(refresh)],
            expectedCursor: separated.cursor
        )
        let beforeInvalidAppend = try pinnedEncoder().encode(separated)
        XCTAssertThrowsError(
            try separated.append(
                [.lifecycle(finalRead)],
                expectedCursor: separated.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .finalReadSourceBindingMismatch(
                    sequence: separated.cursor.eventCount + 1
                )
            )
        }
        XCTAssertEqual(try pinnedEncoder().encode(separated), beforeInvalidAppend)

        let forgedEvidence = try FinalReadEvidence(
            attemptID: "different-source-attempt",
            readAt: evidence.readAt,
            monotonicInstant: evidence.monotonicInstant,
            evaluableOrdinals: evidence.evaluableOrdinals,
            acceptedScoreOrdinals: evidence.acceptedScoreOrdinals,
            missingOrdinals: evidence.missingOrdinals,
            unavailableOrdinals: evidence.unavailableOrdinals,
            completeWindowContent: evidence.completeWindowContent,
            opponentPlanIsFinal: evidence.opponentPlanIsFinal
        )
        let forgedFinalRead = try engine.recordFinalRead(
            projection.competition,
            evidence: forgedEvidence
        )
        var forged = source
        XCTAssertThrowsError(
            try forged.append(
                [
                    .activityRefreshAttemptRecorded(refresh),
                    .lifecycle(forgedFinalRead),
                ],
                expectedCursor: forged.cursor
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .finalReadSourceBindingMismatch(
                    sequence: forged.cursor.eventCount + 2
                )
            )
        }
    }

    func testPauseStateUnknownIsStableAndLegacyV1SnapshotPayloadStillReplays() throws {
        let unknown = ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 3, goal: 1),
            exercise: try ActivityRingReading(value: 0, goal: 1),
            standOrRoll: try ActivityRingReading(value: 0, goal: 1),
            pauseState: .unknown
        )
        let roundTripped = try pinnedDecoder().decode(
            ActivitySnapshot.self,
            from: pinnedEncoder().encode(unknown)
        )
        XCTAssertEqual(roundTripped.pauseState, .unknown)
        XCTAssertEqual(roundTripped.fingerprint, unknown.fingerprint)
        XCTAssertEqual(
            ActivityScoreCalculator.score(roundTripped).unavailableReasons,
            [.summaryPauseStateUnknown]
        )
        let scoreUnknownPolicy = try ActivityScoringPolicy(
            pausedSummaryPolicy: .scoreReportedValues
        )
        XCTAssertEqual(
            ActivityScoreCalculator.score(
                roundTripped,
                policy: scoreUnknownPolicy
            ).availableScore?.points,
            300
        )

        let genesis = try makeGenesis(expiresAt: nil)
        let empty = try CompetitionJournal(genesis: genesis)
        let acceptance = try acceptanceEvent()
        let acceptancePayload = try pinnedEncoder().encode(
            LegacyCompetitionDomainEventV1.lifecycle(acceptance)
        )
        let acceptanceEnvelope = CompetitionJournalEnvelope(
            payloadVersion: 1,
            commitRevision: 1,
            sequence: 1,
            streamID: competitionID,
            semanticEventID: acceptance.id,
            payload: acceptancePayload,
            previousEnvelopeSHA256: empty.genesisDigest
        )
        let legacyObservation = LegacyActivitySnapshotRecordedV1(
            semanticEventID: ActivitySnapshotRecorded.semanticID(
                competitionID: competitionID,
                observationID: "legacy-v1-running"
            ),
            observationID: "legacy-v1-running",
            competitionID: competitionID,
            observedAt: date(2026, 8, 10, 12),
            dayOrdinal: 1,
            snapshot: LegacyActivitySnapshotV1(
                moveMode: .activeEnergyKilocalories,
                standMode: .standHours,
                move: try ActivityRingReading(value: 3, goal: 1),
                exercise: try ActivityRingReading(value: 0, goal: 1),
                standOrRoll: try ActivityRingReading(value: 0, goal: 1),
                isPaused: false
            )
        )
        let legacyPayload = try pinnedEncoder().encode(
            LegacyCompetitionDomainEventV1.activitySnapshotRecorded(
                legacyObservation
            )
        )
        XCTAssertEqual(
            SHA256Digest.hexDigest(legacyPayload),
            "58063b656a4a95a34e045aeb386fed4da4fec1fa3ca7d7a253583db5d8512fbb"
        )
        let observationEnvelope = CompetitionJournalEnvelope(
            payloadVersion: 1,
            commitRevision: 2,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: legacyObservation.semanticEventID,
            payload: legacyPayload,
            previousEnvelopeSHA256: acceptanceEnvelope.envelopeSHA256
        )
        let legacyJournal = try CompetitionJournal(
            validating: genesis,
            envelopes: [acceptanceEnvelope, observationEnvelope]
        )
        let replayed = try CompetitionReplayer.replay(legacyJournal)

        XCTAssertEqual(legacyJournal.envelopes.map(\.payloadVersion), [1, 1])
        XCTAssertEqual(
            replayed.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot.pauseState,
            .running
        )
        XCTAssertEqual(
            replayed.scoreLedger.entry(forDayOrdinal: 1)?
                .latestEvidence.snapshot.fingerprint,
            try snapshot(points: 300).fingerprint
        )
        XCTAssertEqual(replayed.activityRefresh.nextAttemptOrdinal, 1)

        let unknownStandObservation = LegacyActivitySnapshotRecordedV1(
            semanticEventID: ActivitySnapshotRecorded.semanticID(
                competitionID: competitionID,
                observationID: "legacy-v1-unknown-stand"
            ),
            observationID: "legacy-v1-unknown-stand",
            competitionID: competitionID,
            observedAt: date(2026, 8, 10, 12),
            dayOrdinal: 1,
            snapshot: LegacyActivitySnapshotV1(
                moveMode: .activeEnergyKilocalories,
                standMode: .unknown,
                move: try ActivityRingReading(value: 3, goal: 1),
                exercise: try ActivityRingReading(value: 0, goal: 1),
                standOrRoll: try ActivityRingReading(value: 0, goal: 1),
                isPaused: false
            )
        )
        let unknownStandPayload = try pinnedEncoder().encode(
            LegacyCompetitionDomainEventV1.activitySnapshotRecorded(
                unknownStandObservation
            )
        )
        let unknownStandEnvelope = CompetitionJournalEnvelope(
            payloadVersion: 1,
            commitRevision: 2,
            sequence: 2,
            streamID: competitionID,
            semanticEventID: unknownStandObservation.semanticEventID,
            payload: unknownStandPayload,
            previousEnvelopeSHA256: acceptanceEnvelope.envelopeSHA256
        )
        XCTAssertThrowsError(
            try CompetitionJournal(
                validating: genesis,
                envelopes: [acceptanceEnvelope, unknownStandEnvelope]
            )
        ) { error in
            XCTAssertEqual(
                error as? CompetitionJournalError,
                .invalidDomainTransition(sequence: 2)
            )
        }
    }

    private func makeGenesis() throws -> CompetitionGenesis {
        try makeGenesis(expiresAt: date(2026, 8, 10, 10))
    }

    private func makeGenesis(expiresAt: Date?) throws -> CompetitionGenesis {
        try CompetitionGenesis(
            competitionID: competitionID,
            direction: .incoming,
            createdAt: date(2026, 8, 9, 10),
            expiresAt: expiresAt,
            scoringPolicy: .appleCompatibility,
            downwardRevisionPolicy: .maximumObserved
        )
    }

    private func acceptanceEvent() throws -> CompetitionEvent {
        let competition = try makeGenesis(expiresAt: nil).makeCompetition()
        return try engine.accept(
            competition,
            at: date(2026, 8, 9, 11),
            timeZoneIdentifier: "America/Los_Angeles",
            opponent: OpponentPlanGenerationRequest(
                seed: 42,
                generatorVersion: .v1,
                difficulty: .balanced
            )
        )
    }

    private func acceptedJournal() throws -> CompetitionJournal {
        var journal = try CompetitionJournal(genesis: makeGenesis(expiresAt: nil))
        _ = try journal.append(
            [.lifecycle(try acceptanceEvent())],
            expectedCursor: journal.cursor
        )
        return journal
    }

    private func tallyingJournal() throws -> CompetitionJournal {
        var journal = try acceptedJournal()
        let competition = try CompetitionReplayer.replay(journal).competition
        let events = try engine.observeClock(
            competition,
            at: date(2026, 8, 17, 0)
        )
        _ = try journal.append(
            events.map(CompetitionDomainEvent.lifecycle),
            expectedCursor: journal.cursor
        )
        return journal
    }

    private func journalWithSevenOwnerDays(
        from source: CompetitionJournal,
        points: (Int) throws -> Double
    ) throws -> CompetitionJournal {
        var journal = source
        let projection = try CompetitionReplayer.replay(journal)
        let ordinal = projection.activityRefresh.nextAttemptOrdinal
        let readAt = date(2026, 8, 17, 0).addingTimeInterval(
            TimeInterval(ordinal)
        )
        let snapshots = try (1...7).map { dayOrdinal in
            try snapshot(points: points(dayOrdinal))
        }
        let refresh = try refreshAttempt(
            in: projection,
            attemptID: "owner-window-refresh-\(ordinal)",
            ordinal: ordinal,
            readAt: readAt,
            trigger: .reconciliationProbe,
            availability: { dayOrdinal in
                .observed(snapshots[dayOrdinal - 1])
            }
        )
        _ = try journal.append(
            [.activityRefreshAttemptRecorded(refresh)],
            expectedCursor: journal.cursor
        )
        return journal
    }

    private func completeContent(
        for projection: CompetitionReplayProjection
    ) throws -> CompleteWindowContent {
        try XCTUnwrap(projection.competition.opponentPlan).finalScoreWindow
            .completeWindowContent(
                ownerWindow: try XCTUnwrap(
                    projection.scoreLedger.completeLiveWindowObservation()
                )
            )
    }

    private func completeEvidence(
        attemptID: String,
        ordinals: Set<Int>,
        projection: CompetitionReplayProjection
    ) throws -> FinalReadEvidence {
        try FinalReadEvidence(
            attemptID: attemptID,
            readAt: date(2026, 8, 17, 0, 1),
            monotonicInstant: MonotonicInstant(
                epochID: "canonical-test",
                nanoseconds: 9_007_199_254_740_993
            ),
            evaluableOrdinals: ordinals,
            acceptedScoreOrdinals: ordinals,
            missingOrdinals: [],
            unavailableOrdinals: [],
            completeWindowContent: try completeContent(for: projection),
            opponentPlanIsFinal: true
        )
    }

    private func refreshBound(
        to evidence: FinalReadEvidence,
        in projection: CompetitionReplayProjection
    ) throws -> ActivityRefreshAttemptRecorded {
        try ActivityRefreshAttemptRecorded(
            attemptID: evidence.attemptID,
            competitionID: competitionID,
            attemptOrdinal: projection.activityRefresh.nextAttemptOrdinal,
            trigger: .reconciliationProbe,
            attemptedAt: evidence.readAt.addingTimeInterval(-1),
            readAt: evidence.readAt,
            monotonicInstant: evidence.monotonicInstant,
            readStatus: .completed,
            days: try refreshDays(in: projection) { ordinal in
                if evidence.evaluableOrdinals.contains(ordinal) {
                    return .observed(
                        try XCTUnwrap(
                            projection.scoreLedger.entry(
                                forDayOrdinal: ordinal
                            )?.latestEvidence.snapshot
                        )
                    )
                }
                if evidence.missingOrdinals.contains(ordinal) {
                    return .missing
                }
                return .unavailable(reason: .sourceDataUnavailable)
            }
        )
    }

    private func journalJSONObject(
        _ journal: CompetitionJournal
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: pinnedEncoder().encode(journal))
                as? [String: Any]
        )
    }

    private func completedJournal(
        ownerPoints: (Int, Double) throws -> Double
    ) throws -> CompetitionJournal {
        var journal = try stableReadJournal(ownerPoints: ownerPoints)
        let projection = try CompetitionReplayer.replay(journal)
        let policy = FinalizationPolicy(
            minimumStabilityNanoseconds: 1_000,
            bestAvailableDeadline: date(2026, 8, 18, 0)
        )
        guard case let .finalize(authorization) = policy.decision(
            for: projection.competition,
            at: date(2026, 8, 17, 0, 3)
        ) else {
            throw FixtureError.notReadyToFinalize
        }
        let finalized = try engine.finalize(
            projection.competition,
            authorization: authorization,
            at: date(2026, 8, 17, 0, 3)
        )
        _ = try journal.append(
            [.lifecycle(finalized)],
            expectedCursor: journal.cursor
        )
        return journal
    }

    private func stableReadJournal(
        ownerPoints: (Int, Double) throws -> Double
    ) throws -> CompetitionJournal {
        var journal = try tallyingJournal()
        let plan = try XCTUnwrap(
            CompetitionReplayer.replay(journal).competition.opponentPlan
        )
        journal = try journalWithSevenOwnerDays(from: journal) { ordinal in
            try ownerPoints(ordinal, Double(plan.days[ordinal - 1].finalPoints))
        }

        for attempt in 1...2 {
            let projection = try CompetitionReplayer.replay(journal)
            let evidence = try FinalReadEvidence(
                attemptID: "stable-\(attempt)",
                readAt: date(2026, 8, 17, 0, attempt),
                monotonicInstant: MonotonicInstant(
                    epochID: "replay-test",
                    nanoseconds: UInt64(attempt * 1_000)
                ),
                evaluableOrdinals: Set(1...7),
                acceptedScoreOrdinals: Set(1...7),
                missingOrdinals: [],
                unavailableOrdinals: [],
                completeWindowContent: try completeContent(for: projection),
                opponentPlanIsFinal: true
            )
            let event = try engine.recordFinalRead(
                projection.competition,
                evidence: evidence
            )
            let refresh = try refreshBound(to: evidence, in: projection)
            _ = try journal.append(
                [
                    .activityRefreshAttemptRecorded(refresh),
                    .lifecycle(event),
                ],
                expectedCursor: journal.cursor
            )
        }
        return journal
    }

    private enum FixtureError: Error {
        case notReadyToFinalize
    }

    private func observation(
        id: String,
        at observedAt: Date,
        points: Double
    ) throws -> ActivitySnapshotRecorded {
        try ActivitySnapshotRecorded(
            observationID: id,
            competitionID: competitionID,
            observedAt: observedAt,
            dayOrdinal: 1,
            snapshot: try snapshot(points: points)
        )
    }

    private func refreshAttempt(
        in projection: CompetitionReplayProjection,
        attemptID: String,
        ordinal: UInt64,
        attemptedAt: Date? = nil,
        readAt: Date? = nil,
        trigger: ActivityRefreshTrigger = .foreground,
        readStatus: ActivityRefreshReadStatus = .completed,
        availability: ((Int) throws -> ActivityDayAvailability)? = nil
    ) throws -> ActivityRefreshAttemptRecorded {
        let resolvedReadAt = readAt ?? date(2026, 8, 10, 12, Int(ordinal))
        return try ActivityRefreshAttemptRecorded(
            attemptID: attemptID,
            competitionID: competitionID,
            attemptOrdinal: ordinal,
            trigger: trigger,
            attemptedAt: attemptedAt ?? resolvedReadAt.addingTimeInterval(-1),
            readAt: resolvedReadAt,
            monotonicInstant: MonotonicInstant(
                epochID: "boot-a",
                nanoseconds: ordinal * 1_000
            ),
            readStatus: readStatus,
            days: try refreshDays(in: projection) { dayOrdinal in
                if let availability {
                    return try availability(dayOrdinal)
                }
                return .observed(try snapshot(points: 300))
            }
        )
    }

    private func dayOneRefresh(
        in projection: CompetitionReplayProjection,
        attemptID: String,
        ordinal: UInt64,
        readAt: Date,
        snapshot: ActivitySnapshot,
        trigger: ActivityRefreshTrigger = .foreground
    ) throws -> ActivityRefreshAttemptRecorded {
        try refreshAttempt(
            in: projection,
            attemptID: attemptID,
            ordinal: ordinal,
            readAt: readAt,
            trigger: trigger,
            availability: { dayOrdinal in
                dayOrdinal == 1 ? .observed(snapshot) : .notYetOccurred
            }
        )
    }

    private func refreshDays(
        in projection: CompetitionReplayProjection,
        availability: (Int) throws -> ActivityDayAvailability
    ) throws -> [ActivityDayObservation] {
        let schedule = try XCTUnwrap(projection.competition.schedule)
        let days = try schedule.calendar.sevenDayWindow(
            startingOn: schedule.startDay
        )
        return try zip(1...7, days).map { ordinal, day in
            ActivityDayObservation(
                day: day,
                ordinal: ordinal,
                availability: try availability(ordinal)
            )
        }
    }

    private func snapshot(points: Double) throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: points / 100, goal: 1),
            exercise: try ActivityRingReading(value: 0, goal: 1),
            standOrRoll: try ActivityRingReading(value: 0, goal: 1),
            isPaused: false
        )
    }

    private func pinnedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func pinnedDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}

private struct LegacyActivitySnapshotV1: Codable {
    let moveMode: ActivityMoveMode
    let standMode: ActivityStandMode
    let move: ActivityRingReading
    let exercise: ActivityRingReading
    let standOrRoll: ActivityRingReading
    let isPaused: Bool
}

private struct LegacyActivitySnapshotRecordedV1: Codable {
    let semanticEventID: String
    let observationID: String
    let competitionID: CompetitionID
    let observedAt: Date
    let dayOrdinal: Int
    let snapshot: LegacyActivitySnapshotV1
}

private enum LegacyCompetitionDomainEventV1: Codable {
    case lifecycle(CompetitionEvent)
    case activitySnapshotRecorded(LegacyActivitySnapshotRecordedV1)
}
