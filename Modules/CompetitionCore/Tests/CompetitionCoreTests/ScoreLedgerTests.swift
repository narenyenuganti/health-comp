import XCTest
@testable import CompetitionCore

final class ScoreLedgerTests: XCTestCase {
    func testMaximumObservedPolicyKeepsLatestAndAcceptedLedgersSeparate() throws {
        var ledger = ScoreLedger()
        let high = try snapshot(points: 450)
        let low = try snapshot(points: 225)

        _ = try ledger.record(high, forDayOrdinal: 1)
        let revised = try ledger.record(low, forDayOrdinal: 1)

        XCTAssertEqual(revised.latestEvidence.snapshot, low)
        XCTAssertEqual(revised.latestEvidence.result.availableScore?.points, 225)
        XCTAssertEqual(revised.acceptedScore?.points, 450)
        XCTAssertEqual(revised.acceptedScore?.snapshot, high)
    }

    func testLatestValueRevisionPolicyCanAcceptADecrease() throws {
        var ledger = ScoreLedger(downwardRevisionPolicy: .latestValue)

        _ = try ledger.record(try snapshot(points: 450), forDayOrdinal: 2)
        let revised = try ledger.record(
            try snapshot(points: 225),
            forDayOrdinal: 2
        )

        XCTAssertEqual(revised.latestEvidence.result.availableScore?.points, 225)
        XCTAssertEqual(revised.acceptedScore?.points, 225)
    }

    func testUnavailableRevisionUpdatesLatestEvidenceWithoutCreatingAcceptedZero() throws {
        var ledger = ScoreLedger()
        let unavailable = try unavailableSnapshot()

        let entry = try ledger.record(unavailable, forDayOrdinal: 3)

        XCTAssertEqual(entry.latestEvidence.snapshot, unavailable)
        XCTAssertNil(entry.latestEvidence.result.availableScore)
        XCTAssertEqual(
            entry.latestEvidence.result.unavailableReasons,
            [.missingMoveGoal]
        )
        XCTAssertNil(entry.acceptedScore)
    }

    func testUnavailableRevisionDoesNotEraseAnExistingAcceptedScore() throws {
        var ledger = ScoreLedger()
        let acceptedSnapshot = try snapshot(points: 300)
        let unavailable = try unavailableSnapshot()

        _ = try ledger.record(acceptedSnapshot, forDayOrdinal: 3)
        let entry = try ledger.record(unavailable, forDayOrdinal: 3)

        XCTAssertEqual(entry.latestEvidence.snapshot, unavailable)
        XCTAssertEqual(entry.acceptedScore?.points, 300)
        XCTAssertEqual(entry.acceptedScore?.snapshot, acceptedSnapshot)
    }

    func testLateWatchDataCanRaiseAnyPriorDayBeforeFreeze() throws {
        var ledger = ScoreLedger()
        for ordinal in 1...7 {
            _ = try ledger.record(
                try snapshot(points: Double(ordinal * 10)),
                forDayOrdinal: ordinal
            )
        }

        let revisedDayOne = try ledger.record(
            try snapshot(points: 575),
            forDayOrdinal: 1
        )

        XCTAssertEqual(revisedDayOne.acceptedScore?.points, 575)
        XCTAssertFalse(revisedDayOne.isFrozen)
    }

    func testSameDayMoveOrStandModeChangeIsRejectedWithoutMutation() throws {
        var ledger = ScoreLedger()
        _ = try ledger.record(try snapshot(points: 300), forDayOrdinal: 1)
        let before = try XCTUnwrap(ledger.entry(forDayOrdinal: 1))

        XCTAssertThrowsError(
            try ledger.record(
                try snapshot(points: 300, moveMode: .moveMinutes),
                forDayOrdinal: 1
            )
        ) { error in
            XCTAssertEqual(error as? ScoreLedgerError, .activityModeChanged)
        }
        XCTAssertEqual(ledger.entry(forDayOrdinal: 1), before)

        XCTAssertThrowsError(
            try ledger.record(
                try snapshot(points: 300, standMode: .rollHours),
                forDayOrdinal: 1
            )
        ) { error in
            XCTAssertEqual(error as? ScoreLedgerError, .activityModeChanged)
        }
        XCTAssertEqual(ledger.entry(forDayOrdinal: 1), before)
    }

    func testFailedFreezeIsAtomicAndLeavesEveryEntryMutable() throws {
        var ledger = ScoreLedger()
        for ordinal in 1...6 {
            _ = try ledger.record(
                try snapshot(points: Double(ordinal * 10)),
                forDayOrdinal: ordinal
            )
        }

        XCTAssertThrowsError(try ledger.freeze()) { error in
            XCTAssertEqual(
                error as? ScoreLedgerError,
                .missingAcceptedDayOrdinals([7])
            )
        }
        XCTAssertFalse(ledger.isFrozen)
        XCTAssertTrue(ledger.entries.allSatisfy { !$0.isFrozen })

        let revised = try ledger.record(
            try snapshot(points: 500),
            forDayOrdinal: 1
        )
        XCTAssertEqual(revised.acceptedScore?.points, 500)
    }

    func testFreezeRequiresExactlySevenDistinctAcceptedDayOrdinals() throws {
        var ledger = ScoreLedger()
        for ordinal in 1...7 {
            _ = try ledger.record(
                try snapshot(points: Double(ordinal)),
                forDayOrdinal: ordinal
            )
        }
        _ = try ledger.record(try snapshot(points: 99), forDayOrdinal: 7)

        let frozen = try ledger.freeze()

        XCTAssertEqual(frozen.days.map(\.ordinal), Array(1...7))
        XCTAssertEqual(Set(frozen.days.map(\.ordinal)).count, 7)
        XCTAssertEqual(frozen.day(forOrdinal: 7)?.points, 99)
    }

    func testSuccessfulFreezeIsAtomicIdempotentAndCapsTotalAtFortyTwoHundred() throws {
        var ledger = ScoreLedger()
        for ordinal in 1...7 {
            _ = try ledger.record(
                try snapshot(points: 600),
                forDayOrdinal: ordinal
            )
        }

        let first = try ledger.freeze()
        let second = try ledger.freeze()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.totalPoints, 4_200)
        XCTAssertEqual(first.totalPoints, FrozenScoreWindow.maximumTotalPoints)
        XCTAssertTrue(ledger.isFrozen)
        XCTAssertTrue(ledger.entries.allSatisfy(\.isFrozen))
    }

    func testFrozenEntriesRejectLateRevisionsWithoutChangingEitherLedger() throws {
        var ledger = try completeLedger(points: 100)
        _ = try ledger.freeze()
        let before = try XCTUnwrap(ledger.entry(forDayOrdinal: 4))

        XCTAssertThrowsError(
            try ledger.record(
                try snapshot(points: 500),
                forDayOrdinal: 4
            )
        ) { error in
            XCTAssertEqual(error as? ScoreLedgerError, .ledgerFrozen)
        }

        XCTAssertEqual(ledger.entry(forDayOrdinal: 4), before)
    }

    func testAcceptedScoreAlwaysCarriesTheSnapshotThatProducedItsFingerprint() throws {
        var ledger = ScoreLedger()
        let high = try snapshot(points: 400)
        let lowerLatest = try snapshot(points: 200, useExerciseRing: true)

        _ = try ledger.record(high, forDayOrdinal: 1)
        let entry = try ledger.record(lowerLatest, forDayOrdinal: 1)

        XCTAssertEqual(
            entry.latestEvidence.sourceSnapshotFingerprint,
            lowerLatest.fingerprint
        )
        XCTAssertEqual(
            entry.acceptedScore?.sourceSnapshotFingerprint,
            high.fingerprint
        )
        XCTAssertEqual(
            entry.acceptedScore?.sourceSnapshotFingerprint,
            entry.acceptedScore?.snapshot.fingerprint
        )
        XCTAssertNotEqual(
            entry.acceptedScore?.sourceSnapshotFingerprint,
            entry.latestEvidence.sourceSnapshotFingerprint
        )
    }

    func testEqualMaximumPreservesFirstAcceptedEvidenceDeterministically() throws {
        var ledger = ScoreLedger()
        let moveBased = try snapshot(points: 300)
        let exerciseBased = try snapshot(points: 300, useExerciseRing: true)

        _ = try ledger.record(moveBased, forDayOrdinal: 1)
        let entry = try ledger.record(exerciseBased, forDayOrdinal: 1)

        XCTAssertEqual(entry.acceptedScore?.points, 300)
        XCTAssertEqual(entry.acceptedScore?.snapshot, moveBased)
        XCTAssertEqual(
            entry.acceptedScore?.sourceSnapshotFingerprint,
            moveBased.fingerprint
        )
    }

    func testLiveWindowObservationDoesNotFreezeAndTracksLowerRawRevision() throws {
        var ledger = try completeLedger(points: 100)
        let first = try XCTUnwrap(ledger.completeLiveWindowObservation())
        let firstDay = try XCTUnwrap(first.day(forOrdinal: 1))

        _ = try ledger.record(try snapshot(points: 50), forDayOrdinal: 1)
        let revised = try XCTUnwrap(ledger.completeLiveWindowObservation())
        let revisedDay = try XCTUnwrap(revised.day(forOrdinal: 1))

        XCTAssertFalse(ledger.isFrozen)
        XCTAssertTrue(ledger.entries.allSatisfy { !$0.isFrozen })
        XCTAssertEqual(firstDay.acceptedPoints, 100)
        XCTAssertEqual(revisedDay.acceptedPoints, 100)
        XCTAssertNotEqual(
            firstDay.activityContentFingerprint,
            revisedDay.activityContentFingerprint
        )
        XCTAssertTrue(
            revisedDay.activityContentFingerprint.rawValue
                .hasPrefix("live-day-score:v1:")
        )

        let raised = try ledger.record(
            try snapshot(points: 500),
            forDayOrdinal: 1
        )
        XCTAssertEqual(raised.acceptedScore?.points, 500)
        XCTAssertFalse(ledger.isFrozen)
    }

    func testLiveWindowRequiresSevenAvailableLatestEvidences() throws {
        var incomplete = ScoreLedger()
        for ordinal in 1...6 {
            _ = try incomplete.record(
                try snapshot(points: 100),
                forDayOrdinal: ordinal
            )
        }
        XCTAssertNil(incomplete.completeLiveWindowObservation())

        var unavailableLatest = try completeLedger(points: 100)
        _ = try unavailableLatest.record(
            try unavailableSnapshot(),
            forDayOrdinal: 1
        )

        XCTAssertEqual(
            unavailableLatest.entry(forDayOrdinal: 1)?.acceptedScore?.points,
            100
        )
        XCTAssertNil(unavailableLatest.completeLiveWindowObservation())
        XCTAssertFalse(unavailableLatest.isFrozen)
    }

    func testFreezeClosesLiveReconciliationProjection() throws {
        var ledger = try completeLedger(points: 100)
        XCTAssertNotNil(ledger.completeLiveWindowObservation())

        let frozen = try ledger.freeze()

        XCTAssertEqual(ledger.frozenWindow, frozen)
        XCTAssertNil(ledger.completeLiveWindowObservation())
    }

    func testLiveWindowCodablePersistsSourcesAndRejectsModeMismatch() throws {
        let ledger = try completeLedger(points: 100)
        let observation = try XCTUnwrap(
            ledger.completeLiveWindowObservation()
        )
        let encoded = try JSONEncoder().encode(observation)
        let encodedText = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)
        )

        XCTAssertFalse(encodedText.contains("\"acceptedPoints\""))
        XCTAssertFalse(
            encodedText.contains("\"activityContentFingerprint\"")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                LiveScoreWindowObservation.self,
                from: encoded
            ),
            observation
        )

        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var days = try XCTUnwrap(root["days"] as? [[String: Any]])
        var latestEvidence = try XCTUnwrap(
            days[0]["latestEvidence"] as? [String: Any]
        )
        var latestSnapshot = try XCTUnwrap(
            latestEvidence["snapshot"] as? [String: Any]
        )
        latestSnapshot["moveMode"] = "moveMinutes"
        latestEvidence["snapshot"] = latestSnapshot
        days[0]["latestEvidence"] = latestEvidence
        root["days"] = days
        let tampered = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LiveScoreWindowObservation.self,
                from: tampered
            )
        )
    }

    func testLiveWindowDecodeRejectsAcceptedPointsBelowLatestCandidate() throws {
        let ledger = try completeLedger(points: 400)
        let observation = try XCTUnwrap(
            ledger.completeLiveWindowObservation()
        )
        let encoded = try JSONEncoder().encode(observation)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var days = try XCTUnwrap(root["days"] as? [[String: Any]])
        var latestEvidence = try XCTUnwrap(
            days[0]["latestEvidence"] as? [String: Any]
        )
        var latestSnapshot = try XCTUnwrap(
            latestEvidence["snapshot"] as? [String: Any]
        )
        var move = try XCTUnwrap(
            latestSnapshot["move"] as? [String: Any]
        )
        move["value"] = 5.0
        latestSnapshot["move"] = move
        latestEvidence["snapshot"] = latestSnapshot
        days[0]["latestEvidence"] = latestEvidence
        root["days"] = days
        let tampered = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                LiveScoreWindowObservation.self,
                from: tampered
            )
        )
    }

    func testLiveWindowDecodeAcceptsHigherMaximumAndEqualTieEvidence() throws {
        var higherAccepted = try completeLedger(points: 100)
        _ = try higherAccepted.record(
            try snapshot(points: 500),
            forDayOrdinal: 1
        )
        _ = try higherAccepted.record(
            try snapshot(points: 400),
            forDayOrdinal: 1
        )

        var equalTie = try completeLedger(points: 100)
        _ = try equalTie.record(
            try snapshot(points: 400),
            forDayOrdinal: 1
        )
        _ = try equalTie.record(
            try snapshot(points: 400, useExerciseRing: true),
            forDayOrdinal: 1
        )

        for ledger in [higherAccepted, equalTie] {
            let observation = try XCTUnwrap(
                ledger.completeLiveWindowObservation()
            )
            let data = try JSONEncoder().encode(observation)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    LiveScoreWindowObservation.self,
                    from: data
                ),
                observation
            )
        }
    }

    func testMaximumObservedComparesWholeScoresWithoutMixingPerRingMaxima() throws {
        var ledger = ScoreLedger()
        let moveOnly = try snapshot(points: 200)
        let exerciseOnly = try snapshot(points: 200, useExerciseRing: true)

        _ = try ledger.record(moveOnly, forDayOrdinal: 1)
        let entry = try ledger.record(exerciseOnly, forDayOrdinal: 1)

        XCTAssertEqual(entry.latestEvidence.result.availableScore?.points, 200)
        XCTAssertEqual(entry.acceptedScore?.points, 200)
        XCTAssertEqual(entry.acceptedScore?.snapshot, moveOnly)
        XCTAssertNotEqual(entry.acceptedScore?.points, 400)
    }

    func testAcceptedEntryCarriesPolicyAndModeIdentityForReproduction() throws {
        var ledger = ScoreLedger()
        let source = try ActivitySnapshot(
            moveMode: .moveMinutes,
            standMode: .rollHours,
            move: ActivityRingReading(value: 80, goal: 40),
            exercise: ActivityRingReading(value: 30, goal: 30),
            standOrRoll: ActivityRingReading(value: 12, goal: 12),
            isPaused: false
        )

        let accepted = try XCTUnwrap(
            ledger.record(source, forDayOrdinal: 1).acceptedScore
        )

        XCTAssertEqual(
            accepted.scoringPolicyIdentity,
            ActivityScoringPolicy.appleCompatibility.identity
        )
        XCTAssertEqual(accepted.scoringPolicy, .appleCompatibility)
        XCTAssertEqual(accepted.moveMode, .moveMinutes)
        XCTAssertEqual(accepted.standMode, .rollHours)
        XCTAssertEqual(accepted.sourceSnapshotFingerprint, source.fingerprint)
        XCTAssertEqual(
            ActivityScoreCalculator.score(
                accepted.snapshot,
                policy: accepted.scoringPolicy
            ).availableScore?.points,
            accepted.points
        )
    }

    func testUnknownStandModeLedgerRoundTripPreservesModeIdentity() throws {
        var ledger = ScoreLedger()
        let source = try ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .unknown,
            move: ActivityRingReading(value: 1, goal: 1),
            exercise: ActivityRingReading(value: 1, goal: 1),
            standOrRoll: ActivityRingReading(value: 9, goal: 12),
            isPaused: false
        )
        _ = try ledger.record(source, forDayOrdinal: 1)

        let roundTripped = try JSONDecoder().decode(
            ScoreLedger.self,
            from: JSONEncoder().encode(ledger)
        )
        let accepted = try XCTUnwrap(
            roundTripped.entry(forDayOrdinal: 1)?.acceptedScore
        )

        XCTAssertEqual(accepted.standMode, .unknown)
        XCTAssertEqual(accepted.snapshot, source)
        XCTAssertEqual(
            accepted.scoringPolicyIdentity,
            ActivityScoringPolicy.appleCompatibility.identity
        )
        XCTAssertEqual(
            ActivityScoreCalculator.score(
                accepted.snapshot,
                policy: accepted.scoringPolicy
            ).availableScore?.points,
            accepted.points
        )

        let beforeModeChange = ledger
        XCTAssertThrowsError(
            try ledger.record(
                ActivitySnapshot(
                    moveMode: source.moveMode,
                    standMode: .standHours,
                    move: source.move,
                    exercise: source.exercise,
                    standOrRoll: source.standOrRoll,
                    pauseState: source.pauseState
                ),
                forDayOrdinal: 1
            )
        ) { error in
            XCTAssertEqual(error as? ScoreLedgerError, .activityModeChanged)
        }
        XCTAssertEqual(ledger, beforeModeChange)
    }

    func testUnknownOnlyPausePolicyPersistsThroughLedgerEvidence() throws {
        let policy = ActivityScoringPolicy.healthKitCompatibility
        var ledger = ScoreLedger(scoringPolicy: policy)
        let running = try snapshot(points: 300)
        let unknown = ActivitySnapshot(
            moveMode: running.moveMode,
            standMode: running.standMode,
            move: running.move,
            exercise: running.exercise,
            standOrRoll: running.standOrRoll,
            pauseState: .unknown
        )
        let paused = ActivitySnapshot(
            moveMode: running.moveMode,
            standMode: running.standMode,
            move: running.move,
            exercise: running.exercise,
            standOrRoll: running.standOrRoll,
            pauseState: .paused
        )

        _ = try ledger.record(running, forDayOrdinal: 1)
        _ = try ledger.record(unknown, forDayOrdinal: 2)
        _ = try ledger.record(paused, forDayOrdinal: 3)
        let roundTripped = try JSONDecoder().decode(
            ScoreLedger.self,
            from: JSONEncoder().encode(ledger)
        )

        XCTAssertEqual(roundTripped.scoringPolicy, policy)
        XCTAssertEqual(
            roundTripped.entry(forDayOrdinal: 1)?.acceptedScore?.points,
            300
        )
        XCTAssertEqual(
            roundTripped.entry(forDayOrdinal: 2)?.acceptedScore?.points,
            300
        )
        XCTAssertEqual(
            roundTripped.entry(forDayOrdinal: 2)?
                .acceptedScore?.scoringPolicyIdentity,
            policy.identity
        )
        XCTAssertNil(
            roundTripped.entry(forDayOrdinal: 3)?.acceptedScore
        )
        XCTAssertEqual(
            roundTripped.entry(forDayOrdinal: 3)?
                .latestEvidence.result.unavailableReasons,
            [.summaryPaused]
        )
    }

    func testFrozenWindowExportsOnlyAcceptedPointsAndFingerprintsToCompleteContent() throws {
        var ledger = ScoreLedger()
        for ordinal in 1...7 {
            _ = try ledger.record(
                try snapshot(points: Double(ordinal * 50)),
                forDayOrdinal: ordinal
            )
        }
        let acceptedDayOne = try XCTUnwrap(
            ledger.entry(forDayOrdinal: 1)?.acceptedScore
        )
        _ = try ledger.record(
            try snapshot(points: 10, useExerciseRing: true),
            forDayOrdinal: 1
        )
        let frozen = try ledger.freeze()
        let opponentPoints = Dictionary(
            uniqueKeysWithValues: (1...7).map { ($0, Double($0 * 40)) }
        )

        let content = try frozen.completeWindowContent(
            opponentPointsByOrdinal: opponentPoints,
            opponentPlanVersion: "seeded-plan-v1"
        )

        XCTAssertEqual(content.days.map(\.userPoints), frozen.days.map(\.points))
        XCTAssertEqual(
            content.days.map(\.activityContentFingerprint),
            frozen.days.map { $0.activityContentFingerprint.rawValue }
        )
        XCTAssertEqual(content.days.first?.userPoints, acceptedDayOne.points)
        XCTAssertEqual(content.days.first?.opponentPoints, 40)
        XCTAssertEqual(content.opponentPlanVersion, "seeded-plan-v1")
    }

    func testCompleteContentExportReportsExtraOpponentOrdinals() throws {
        var ledger = try completeLedger(points: 100)
        let frozen = try ledger.freeze()
        let opponentPoints = Dictionary(
            uniqueKeysWithValues: (1...8).map { ($0, 100.0) }
        )

        XCTAssertThrowsError(
            try frozen.completeWindowContent(
                opponentPointsByOrdinal: opponentPoints,
                opponentPlanVersion: "seeded-plan-v1"
            )
        ) { error in
            XCTAssertEqual(
                error as? ScoreLedgerError,
                .invalidOpponentDayOrdinals([8])
            )
        }
    }

    func testLedgerCodableRoundTripPreservesLatestAcceptedAndFrozenEvidence() throws {
        var ledger = try completeLedger(points: 300)
        _ = try ledger.record(try snapshot(points: 100), forDayOrdinal: 1)
        _ = try ledger.freeze()

        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(ScoreLedger.self, from: data)

        XCTAssertEqual(decoded, ledger)
        XCTAssertEqual(
            decoded.entry(forDayOrdinal: 1)?.latestEvidence.result
                .availableScore?.points,
            100
        )
        XCTAssertEqual(
            decoded.entry(forDayOrdinal: 1)?.acceptedScore?.points,
            300
        )
    }

    func testDecodeRejectsMismatchedLatestEvidencePolicyWhenNoScoreWasAccepted() throws {
        var ledger = ScoreLedger()
        _ = try ledger.record(
            try unavailableSnapshot(),
            forDayOrdinal: 1
        )
        let encoded = try JSONEncoder().encode(ledger)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        var latestEvidence = try XCTUnwrap(
            entries[0]["latestEvidence"] as? [String: Any]
        )
        var policy = try XCTUnwrap(
            latestEvidence["scoringPolicy"] as? [String: Any]
        )
        policy["pausedSummaryPolicy"] = "scoreReportedValues"
        latestEvidence["scoringPolicy"] = policy
        entries[0]["latestEvidence"] = latestEvidence
        root["entries"] = entries
        let tampered = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoreLedger.self, from: tampered)
        )
    }

    func testDecodeRejectsAcceptedAndLatestModeMismatch() throws {
        var ledger = ScoreLedger()
        _ = try ledger.record(try snapshot(points: 100), forDayOrdinal: 1)
        let encoded = try JSONEncoder().encode(ledger)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        var latestEvidence = try XCTUnwrap(
            entries[0]["latestEvidence"] as? [String: Any]
        )
        var latestSnapshot = try XCTUnwrap(
            latestEvidence["snapshot"] as? [String: Any]
        )
        latestSnapshot["standMode"] = "rollHours"
        latestEvidence["snapshot"] = latestSnapshot
        entries[0]["latestEvidence"] = latestEvidence
        root["entries"] = entries
        let tampered = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoreLedger.self, from: tampered)
        )
    }

    func testDecodeRejectsAvailableLatestWithoutAcceptedScore() throws {
        var ledger = ScoreLedger()
        _ = try ledger.record(try snapshot(points: 400), forDayOrdinal: 1)
        let tampered = try tamperedLedgerData(
            ledger,
            removeAcceptedScore: true
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoreLedger.self, from: tampered)
        )
    }

    func testDecodeRejectsAcceptedScoreBelowAvailableLatestForBothPolicies() throws {
        for revisionPolicy in [
            DownwardRevisionPolicy.maximumObserved,
            .latestValue,
        ] {
            var ledger = ScoreLedger(
                downwardRevisionPolicy: revisionPolicy
            )
            _ = try ledger.record(
                try snapshot(points: 400),
                forDayOrdinal: 1
            )
            let tampered = try tamperedLedgerData(
                ledger,
                latestPoints: 500
            )

            XCTAssertThrowsError(
                try JSONDecoder().decode(ScoreLedger.self, from: tampered),
                "Expected rejection for \(revisionPolicy)"
            )
        }
    }

    func testLatestValueDecodeRejectsEqualPointsFromDifferentEvidence() throws {
        var ledger = ScoreLedger(downwardRevisionPolicy: .latestValue)
        _ = try ledger.record(try snapshot(points: 400), forDayOrdinal: 1)
        let tampered = try tamperedLedgerData(
            ledger,
            latestPoints: 400,
            latestUsesExerciseRing: true
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ScoreLedger.self, from: tampered)
        )
    }

    func testDecodeAcceptsReducerReachableRevisionStates() throws {
        var maximumEarlier = ScoreLedger()
        _ = try maximumEarlier.record(
            try snapshot(points: 500),
            forDayOrdinal: 1
        )
        _ = try maximumEarlier.record(
            try snapshot(points: 400),
            forDayOrdinal: 1
        )

        var maximumEqualTie = ScoreLedger()
        _ = try maximumEqualTie.record(
            try snapshot(points: 400),
            forDayOrdinal: 1
        )
        _ = try maximumEqualTie.record(
            try snapshot(points: 400, useExerciseRing: true),
            forDayOrdinal: 1
        )

        var unavailableWithAccepted = ScoreLedger()
        _ = try unavailableWithAccepted.record(
            try snapshot(points: 400),
            forDayOrdinal: 1
        )
        _ = try unavailableWithAccepted.record(
            try unavailableSnapshot(),
            forDayOrdinal: 1
        )

        var unavailableWithoutAccepted = ScoreLedger()
        _ = try unavailableWithoutAccepted.record(
            try unavailableSnapshot(),
            forDayOrdinal: 1
        )

        for ledger in [
            maximumEarlier,
            maximumEqualTie,
            unavailableWithAccepted,
            unavailableWithoutAccepted,
        ] {
            let data = try JSONEncoder().encode(ledger)
            XCTAssertEqual(
                try JSONDecoder().decode(ScoreLedger.self, from: data),
                ledger
            )
        }
    }

    func testCodableCanonicalizesOutOfOrderMutableAndFrozenStorage() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var mutable = ScoreLedger()
        _ = try mutable.record(try snapshot(points: 200), forDayOrdinal: 2)
        _ = try mutable.record(try snapshot(points: 100), forDayOrdinal: 1)

        let mutableData = try encoder.encode(mutable)
        let decodedMutable = try JSONDecoder().decode(
            ScoreLedger.self,
            from: mutableData
        )
        XCTAssertEqual(decodedMutable, mutable)
        XCTAssertEqual(try encoder.encode(decodedMutable), mutableData)

        var frozen = ScoreLedger()
        for ordinal in (1...7).reversed() {
            _ = try frozen.record(
                try snapshot(points: Double(ordinal * 10)),
                forDayOrdinal: ordinal
            )
        }
        _ = try frozen.freeze()

        let frozenData = try encoder.encode(frozen)
        let decodedFrozen = try JSONDecoder().decode(
            ScoreLedger.self,
            from: frozenData
        )
        XCTAssertEqual(decodedFrozen, frozen)
        XCTAssertEqual(try encoder.encode(decodedFrozen), frozenData)
    }

    func testInvalidDayOrdinalIsRejectedBeforeMutation() throws {
        var ledger = ScoreLedger()

        XCTAssertThrowsError(
            try ledger.record(try snapshot(points: 100), forDayOrdinal: 0)
        ) { error in
            XCTAssertEqual(
                error as? ScoreLedgerError,
                .invalidDayOrdinal(0)
            )
        }
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    private func completeLedger(points: Double) throws -> ScoreLedger {
        var ledger = ScoreLedger()
        for ordinal in 1...7 {
            _ = try ledger.record(
                try snapshot(points: points),
                forDayOrdinal: ordinal
            )
        }
        return ledger
    }

    private func snapshot(
        points: Double,
        moveMode: ActivityMoveMode = .activeEnergyKilocalories,
        standMode: ActivityStandMode = .standHours,
        useExerciseRing: Bool = false
    ) throws -> ActivitySnapshot {
        let moveValue = useExerciseRing ? 0 : points / 100
        let exerciseValue = useExerciseRing ? points / 100 : 0
        return ActivitySnapshot(
            moveMode: moveMode,
            standMode: standMode,
            move: try ActivityRingReading(value: moveValue, goal: 1),
            exercise: try ActivityRingReading(value: exerciseValue, goal: 1),
            standOrRoll: try ActivityRingReading(value: 0, goal: 1),
            isPaused: false
        )
    }

    private func unavailableSnapshot() throws -> ActivitySnapshot {
        ActivitySnapshot(
            moveMode: .activeEnergyKilocalories,
            standMode: .standHours,
            move: try ActivityRingReading(value: 1, goal: nil),
            exercise: try ActivityRingReading(value: 0, goal: 1),
            standOrRoll: try ActivityRingReading(value: 0, goal: 1),
            isPaused: false
        )
    }

    private func tamperedLedgerData(
        _ ledger: ScoreLedger,
        latestPoints: Double? = nil,
        latestUsesExerciseRing: Bool = false,
        removeAcceptedScore: Bool = false
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(ledger)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        if removeAcceptedScore {
            entries[0].removeValue(forKey: "acceptedScore")
        }
        if let latestPoints {
            var latestEvidence = try XCTUnwrap(
                entries[0]["latestEvidence"] as? [String: Any]
            )
            var latestSnapshot = try XCTUnwrap(
                latestEvidence["snapshot"] as? [String: Any]
            )
            var move = try XCTUnwrap(
                latestSnapshot["move"] as? [String: Any]
            )
            var exercise = try XCTUnwrap(
                latestSnapshot["exercise"] as? [String: Any]
            )
            move["value"] = latestUsesExerciseRing ? 0 : latestPoints / 100
            exercise["value"] = latestUsesExerciseRing
                ? latestPoints / 100
                : 0
            latestSnapshot["move"] = move
            latestSnapshot["exercise"] = exercise
            latestEvidence["snapshot"] = latestSnapshot
            entries[0]["latestEvidence"] = latestEvidence
        }
        root["entries"] = entries
        return try JSONSerialization.data(withJSONObject: root)
    }
}
